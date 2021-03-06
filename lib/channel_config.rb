class ChannelConfig
  def initialize(input = 'config/channels.yml')
    @config = YAML.load(File.read(input))
  end

  def all_channels
    @config.keys
  end

  def channels_to_notify(project, owner)
    @config.select { |channel, opts|
      opts['project'].include?("#{project}*") ||
      (opts['project'].include?(project) && opts['owner'].include?(owner))
    }.keys
  end

end
