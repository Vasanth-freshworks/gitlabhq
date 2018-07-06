module Gitlab
  module BitbucketServerImport
    class Importer
      include Gitlab::ShellAdapter
      attr_reader :project, :project_key, :repository_slug, :client, :errors, :users

      REMOTE_NAME = 'bitbucket_server'.freeze
      BATCH_SIZE = 100

      def self.imports_repository?
        true
      end

      def self.refmap
        [:heads, :tags, '+refs/pull-requests/*/to:refs/merge-requests/*/head']
      end

      def initialize(project)
        @project = project
        @project_key = project.import_data.data['project_key']
        @repository_slug = project.import_data.data['repo_slug']
        @client = BitbucketServer::Client.new(project.import_data.credentials)
        @formatter = Gitlab::ImportFormatter.new
        @errors = []
        @users = {}
        @temp_branches = []
      end

      def execute
        import_repository
        import_pull_requests
        handle_errors

        true
      end

      private

      def handle_errors
        return unless errors.any?

        project.update_column(:import_error, {
          message: 'The remote data could not be fully imported.',
          errors: errors
        }.to_json)
      end

      def gitlab_user_id(project, email)
        find_user_id(email) || project.creator_id
      end

      def find_user_id(email)
        return nil unless email

        return users[email] if users.key?(email)

        users[email] = User.find_by_any_email(email)
      end

      def repo
        @repo ||= client.repo(project_key, repository_slug)
      end

      def sha_exists?(sha)
        project.repository.commit(sha)
      end

      def temp_branch_name(pull_request, suffix)
        "gitlab/import/pull-request/#{pull_request.iid}/#{suffix}"
      end

      def restore_branches(pull_requests)
        shas_to_restore = []
        pull_requests.each do |pull_request|
          shas_to_restore << {
            temp_branch_name(pull_request, :from) => pull_request.source_branch_sha,
            temp_branch_name(pull_request, :to) => pull_request.target_branch_sha
          }
        end

        created_branches = restore_branch_shas(shas_to_restore)
        @temp_branches << created_branches
        import_repository unless created_branches.empty?
      end

      def restore_branch_shas(shas_to_restore)
        branches_created = []

        shas_to_restore.each_with_index do |shas, index|
          shas.each do |branch_name, sha|
            next if sha_exists?(sha)

            response = client.create_branch(project_key, repository_slug, branch_name, sha)

            if response.success?
              branches_created << branch_name
            else
              Rails.logger.warn("BitbucketServerImporter: Unable to recreate branch for SHA #{sha}: #{response.code}")
            end
          end
        end

        branches_created
      end

      def import_repository
        project.ensure_repository
        project.repository.fetch_as_mirror(project.import_url, refmap: self.class.refmap, remote_name: REMOTE_NAME)
      rescue Gitlab::Shell::Error, Gitlab::Git::RepositoryMirroring::RemoteError => e
        # Expire cache to prevent scenarios such as:
        # 1. First import failed, but the repo was imported successfully, so +exists?+ returns true
        # 2. Retried import, repo is broken or not imported but +exists?+ still returns true
        project.repository.expire_content_cache if project.repository_exists?

        raise e.message
      end

      # Bitbucket Server keeps tracks of references for open pull requests in
      # refs/heads/pull-requests, but closed and merged requests get moved
      # into hidden internal refs under stash-refs/pull-requests. Unless the
      # SHAs involved are at the tip of a branch or tag, there is no way to
      # retrieve the server for those commits.
      #
      # To avoid losing history, we use the Bitbucket API to re-create the branch
      # on the remote server. Then we have to issue a `git fetch` to download these
      # branches.
      def import_pull_requests
        pull_requests = client.pull_requests(project_key, repository_slug).to_a

        # Creating branches on the server and fetching the newly-created branches
        # may take a number of network round-trips. Do this in batches so that we can
        # avoid doing a git fetch for every new branch.
        pull_requests.each_slice(BATCH_SIZE) do |batch|
          restore_branches(batch)

          batch.each do |pull_request|
            begin
              import_bitbucket_pull_request(pull_request)
            rescue StandardError => e
              errors << { type: :pull_request, iid: pull_request.iid, errors: e.message, trace: e.backtrace.join("\n"), raw_response: pull_request.raw }
            end
          end
        end
      end

      def import_bitbucket_pull_request(pull_request)
        description = ''
        description += @formatter.author_line(pull_request.author) unless find_user_id(pull_request.author_email)
        description += pull_request.description

        source_branch_sha = pull_request.source_branch_sha
        target_branch_sha = pull_request.target_branch_sha
        source_branch_sha = project.repository.commit(source_branch_sha)&.sha || source_branch_sha
        target_branch_sha = project.repository.commit(target_branch_sha)&.sha || target_branch_sha
        project.merge_requests.find_by(iid: pull_request.iid)&.destroy

        attributes = {
          iid: pull_request.iid,
          title: pull_request.title,
          description: description,
          source_project: project,
          source_branch: Gitlab::Git.ref_name(pull_request.source_branch_name),
          source_branch_sha: source_branch_sha,
          target_project: project,
          target_branch: Gitlab::Git.ref_name(pull_request.target_branch_name),
          target_branch_sha: target_branch_sha,
          state: pull_request.state,
          author_id: gitlab_user_id(project, pull_request.author_email),
          assignee_id: nil,
          created_at: pull_request.created_at,
          updated_at: pull_request.updated_at
        }

        attributes[:merge_commit_sha] = target_branch_sha if pull_request.merged?
        merge_request = project.merge_requests.create!(attributes)
        import_pull_request_comments(pull_request, merge_request) if merge_request.persisted?
      end

      def import_pull_request_comments(pull_request, merge_request)
        comments, other_activities = client.activities(project_key, repository_slug, pull_request.iid).partition(&:comment?)

        merge_event = other_activities.find(&:merge_event?)
        import_merge_event(merge_request, merge_event) if merge_event

        inline_comments, pr_comments = comments.partition(&:inline_comment?)

        import_inline_comments(inline_comments.map(&:comment), pull_request, merge_request)
        import_standalone_pr_comments(pr_comments.map(&:comment), merge_request)
      end

      def import_merge_event(merge_request, merge_event)
        committer = merge_event.committer_email

        user = User.ghost
        user ||= find_user_id(committer) if committer
        timestamp = merge_event.merge_timestamp
        metric = MergeRequest::Metrics.find_or_initialize_by(merge_request: merge_request)
        metric.update_attributes(merged_by: user, merged_at: timestamp)
      end

      def import_inline_comments(inline_comments, pull_request, merge_request)
        inline_comments.each do |comment|
          parent = build_diff_note(merge_request, comment)

          next unless parent&.persisted?

          comment.comments.each do |reply|
            begin
              attributes = pull_request_comment_attributes(reply)
              attributes.merge!(
                position: build_position(merge_request, comment),
                discussion_id: parent.discussion_id,
                type: 'DiffNote')
              merge_request.notes.create!(attributes)
            rescue StandardError => e
              errors << { type: :pull_request, id: comment.id, errors: e.message }
            end
          end
        end
      end

      def build_diff_note(merge_request, comment)
        attributes = pull_request_comment_attributes(comment)
        attributes.merge!(
          position: build_position(merge_request, comment),
          type: 'DiffNote')

        merge_request.notes.create!(attributes)
      rescue StandardError => e
        errors << { type: :pull_request, id: comment.id, errors: e.message }
        nil
      end

      def build_position(merge_request, pr_comment)
        params = {
          diff_refs: merge_request.diff_refs,
          old_path: pr_comment.file_path,
          new_path: pr_comment.file_path,
          old_line: pr_comment.old_pos,
          new_line: pr_comment.new_pos
        }

        Gitlab::Diff::Position.new(params)
      end

      def import_standalone_pr_comments(pr_comments, merge_request)
        pr_comments.each do |comment|
          begin
            merge_request.notes.create!(pull_request_comment_attributes(comment))

            comment.comments.each do |replies|
              merge_request.notes.create!(pull_request_comment_attributes(replies))
            end
          rescue StandardError => e
            errors << { type: :pull_request, iid: comment.id, errors: e.message }
          end
        end
      end

      def generate_line_code(pr_comment)
        Gitlab::Git.diff_line_code(pr_comment.file_path, pr_comment.new_pos, pr_comment.old_pos)
      end

      def pull_request_comment_attributes(comment)
        {
          project: project,
          note: comment.note,
          author_id: gitlab_user_id(project, comment.author_email),
          created_at: comment.created_at,
          updated_at: comment.updated_at
        }
      end
    end
  end
end
