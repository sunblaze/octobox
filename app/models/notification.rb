# frozen_string_literal: true
class Notification < ApplicationRecord
  include PgSearch
  pg_search_scope :search_by_subject_title,
                  against: :subject_title,
                  using: {
                    tsearch: {
                      prefix: true,
                      negation: true,
                      dictionary: "english"
                    }
                  }

  belongs_to :user
  belongs_to :subject, foreign_key: :subject_url, primary_key: :url, optional: true

  scope :inbox,    -> { where(archived: false) }
  scope :archived, -> { where(archived: true) }
  scope :newest,   -> { order('notifications.updated_at DESC') }
  scope :starred,  -> { where(starred: true) }

  scope :repo,     ->(repo_name)    { where(repository_full_name: repo_name) }
  scope :type,     ->(subject_type) { where(subject_type: subject_type) }
  scope :reason,   ->(reason)       { where(reason: reason) }
  scope :unread,   ->(unread)       { where(unread: unread) }
  scope :owner,    ->(owner_name)   { where(repository_owner_name: owner_name) }

  scope :state,    ->(state) { joins(:subject).where('subjects.state = ?', state) }

  scope :subjectable, -> { where(subject_type: ['Issue', 'PullRequest', 'Commit', 'Release']) }
  scope :without_subject, -> { includes(:subject).where(subjects: { url: nil }) }

  paginates_per 20

  class << self
    def attributes_from_api_response(api_response)
      attrs = DownloadService::API_ATTRIBUTE_MAP.map do |attr, path|
        [attr, api_response.to_h.dig(*path)]
      end.to_h
      if "RepositoryInvitation" == api_response.subject.type
        attrs[:subject_url] = "#{api_response.repository.html_url}/invitations"
      end
      attrs
    end
  end

  def state
    return unless Octobox.config.fetch_subject
    subject.try(:state)
  end

  def mark_read
    self[:unread] = false
    save(touch: false) if changed?
    user.github_client.mark_thread_as_read(github_id, read: true)
  end

  def ignore_thread
    user.github_client.update_thread_subscription(github_id, ignored: true)
  end

  def mute
    user.github_client.mark_thread_as_read(github_id, read: true)
    ignore_thread
    update_columns archived: true, unread: false
  end

  def web_url
    url = subject.try(:html_url) || subject_url # Use the sync'd HTML URL if possible, else the API one
    Octobox::SubjectUrlParser.new(url, latest_comment_url: latest_comment_url)
      .to_html_url
  end

  def repo_url
    "#{Octobox.config.github_domain}/#{repository_full_name}"
  end

  def unarchive_if_updated
    return unless self.archived?
    change = changes['updated_at']
    return unless change
    if self.archived && change[1] > change[0]
      self.archived = false
    end
  end

  def update_from_api_response(api_response, unarchive: false)
    attrs = Notification.attributes_from_api_response(api_response)
    self.attributes = attrs
    update_subject
    unarchive_if_updated if unarchive
    save(touch: false) if changed?
  end

  private

  def download_subject
    user.github_client.get(subject_url)
  rescue Octokit::Forbidden, Octokit::NotFound => e
    Rails.logger.warn("\n\n\033[32m[#{Time.now}] WARNING -- #{e.message}\033[0m\n\n")
  end

  def update_subject
    return unless Octobox.config.fetch_subject
    if subject
      # skip syncing if the notification was updated around the same time as subject
      return if updated_at - subject.updated_at < 2.seconds

      case subject_type
      when 'Issue', 'PullRequest'
        remote_subject = download_subject
        return unless remote_subject.present?

        subject.state = remote_subject.merged_at.present? ? 'merged' : remote_subject.state
        subject.save(touch: false) if subject.changed?
      end
    else
      case subject_type
      when 'Issue', 'PullRequest'
        remote_subject = download_subject
        return unless remote_subject.present?

        create_subject({
          state: remote_subject.merged_at.present? ? 'merged' : remote_subject.state,
          author: remote_subject.user.login,
          html_url: remote_subject.html_url,
          created_at: remote_subject.created_at,
          updated_at: remote_subject.updated_at
        })
      when 'Commit', 'Release'
        remote_subject = download_subject
        return unless remote_subject.present?

        create_subject({
          author: remote_subject.author.login,
          html_url: remote_subject.html_url,
          created_at: remote_subject.created_at,
          updated_at: remote_subject.updated_at
        })
      end
    end
  end
end
