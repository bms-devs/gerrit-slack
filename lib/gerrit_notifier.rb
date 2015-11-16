class GerritNotifier
  extend Alias

  @@buffer = {}
  @@channel_config = nil
  @@semaphore = Mutex.new

  def self.start!
    @@channel_config = ChannelConfig.new
    start_buffer_daemon
    listen_for_updates
  end

  def self.psa!(msg)
    notify @@channel_config.all_channels, msg
  end

  def self.notify(channels, msg)
    channels.each do |channel|
      slack_channel = "#{channel}"
      add_to_buffer slack_channel, msg
    end
  end

  def self.notify_user(user, msg)
    channel = "@#{slack_name_for user}"
    attachment_mock = {}
    attachment_mock['simple_message'] = msg
    add_to_buffer channel, attachment_mock
  end

  def self.add_to_buffer(channel, msg)
    @@semaphore.synchronize do
      @@buffer[channel] ||= []
      @@buffer[channel] << msg
    end
  end

  def self.start_buffer_daemon
    # post every X seconds rather than truly in real-time to group messages
    # to conserve slack-log
    Thread.new do
      slack_config = YAML.load(File.read('config/slack.yml'))['slack']

      while true
        @@semaphore.synchronize do
          if @@buffer == {}
            puts "[#{Time.now}] Buffer is empty"
          else
            puts "[#{Time.now}] Current buffer:"
            ap @@buffer
          end

          if @@buffer.size > 0 && !ENV['DEVELOPMENT']
            @@buffer.each do |channel, attachments|
              attachments.each do |attachment|
                notifier = Slack::Notifier.new slack_config['team'], slack_config['token']
                if attachment['simple_message']
                  notifier.ping(attachment['simple_message'],
                   channel: channel,
                   username: 'Gerrit',
                   link_names: 1
                  )
                else
                  msg_attachments = []
                  msg_attachments << attachment
                  notifier.ping("",
                    channel: channel,
                    username: 'Gerrit',
                    link_names: 1,
                    attachments: msg_attachments
                  )
                end
              end
            end
          end

          @@buffer = {}
        end

        sleep 15
      end
    end
  end

  def self.listen_for_updates
    stream = YAML.load(File.read('config/gerrit.yml'))['gerrit']['stream']
    puts "Listening to stream via #{stream}"

    IO.popen(stream).each do |line|
      update = Update.new(line)
      process_update(update)
    end

    puts "Connection to Gerrit server failed, trying to reconnect."
    sleep 3
    listen_for_updates
  end

  def self.create_slack_attachment_for(update)
    attachment = {}
    attachment['text'] = "<#{update.url}|Change #{update.change_number}>: #{update.subject}"

    field_with_project = {}
    field_with_project['title'] = ''
    field_with_project['value'] = "*#{update.project}* | #{update.branch}"
    field_with_project['value'].length.times do
      field_with_project['title'] << '_'
    end
    field_with_project['short'] = 1

    if update.author
      field_with_author = {}
      field_with_author['title'] = 'Author'
      field_with_author['value'] = "#{update.owner_slack_name}"
      field_with_author['short'] = 1
    end

    attachment['fields'] = []
    attachment['fields'] << field_with_project
    attachment['fields'] << field_with_author
    attachment['mrkdwn_in'] = []
    attachment['mrkdwn_in'] << 'fields'
    attachment['mrkdwn_in'] << 'pretext'
    attachment['mrkdwn_in'] << 'text'
    return attachment
  end

  def self.process_update(update)
    if ENV['DEVELOPMENT']
      ap update.json
      puts update.raw_json
    end

    channels = @@channel_config.channels_to_notify(update.project, update.owner)

    return if channels.size == 0

    # Jenkins update
    if update.jenkins?
      if update.build_failed? && !update.build_aborted?
        notify_user update.owner, "#{update.commit_without_owner} *failed* on Jenkins"
      end
    end

    # Patchset created
    if update.patchset_created?
      attachment = create_slack_attachment_for update
      if update.new_patchset?
        attachment['pretext'] = 'There is a new commit'
        attachment['fallback'] = "There is a new commit: #{update.commit}. Feel free to do the code review."
        attachment['color'] = '#FFFF00'
        notify channels, attachment
      else
        attachment['pretext'] = 'There has been an ammend to commit'
        attachment['fallback'] = "There has been an ammend to commit: #{update.commit}. Feel free to do the code review."
        attachment['color'] = '#FFA500'
        notify channels, attachment
      end
    end

    # Code review +2
    if update.code_review_approved?
      attachment = create_slack_attachment_for update
      attachment['pretext'] = "Change *+2'd* by #{update.author_slack_name}"
      attachment['fallback'] = "#{update.author_slack_name} has *+2'd* #{update.commit}: ready for *merge*"
      attachment['color'] = '#00FF00'
      notify channels, attachment
    end

    # Code review +1
    if update.code_review_tentatively_approved? && update.human?
      attachment = create_slack_attachment_for update
      attachment['pretext'] = "Change *+1'd* by #{update.author_slack_name}"
      attachment['fallback'] = "#{update.author_slack_name} has *+1'd* #{update.commit}: needs another set of eyes for *code review*"
      attachment['color'] = '#B2FFB2'
      notify channels, attachment
    end

    # Any minuses (Code/Product/QA)
    if update.minus_1ed? || update.minus_2ed?
      verb = update.minus_1ed? ? "-1'd" : "-2'd"
      attachment = create_slack_attachment_for update
      attachment['pretext'] = "Change *#{verb}* by #{update.author_slack_name}"
      attachment['fallback'] = "#{update.author_slack_name} has *#{verb}* #{update.commit}"
      attachment['color'] = '#FF0000'
      notify channels, attachment
    end

    # New comment added
    if update.comment_added? && update.human? && update.comment != ''
      attachment = create_slack_attachment_for update
      attachment['pretext'] = "#{update.author_slack_name} has left comments on change"
      attachment['fallback'] = "#{update.author_slack_name} has left *comments* on #{update.commit}: \"#{update.comment}\""
      attachment['color'] = '#0000FF'
      notify channels, attachment
    end

    # Merged
    if update.merged?
      attachment = create_slack_attachment_for update
      attachment['pretext'] = "Change was *merged*!"
      attachment['fallback'] = "#{update.commit} was *merged*!"
      notify channels, attachment
    end
  end
end
