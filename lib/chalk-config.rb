require 'set'
require 'yaml'
require 'chalk-config/version'
require 'chalk-config/errors'

# We don't necessarily need to keep this, but it's preferable to make
# sure no one defines any keys outside of Chalk::Config
if defined?(configatron)
  raise "Someone already loaded 'configatron'. You should let chalk-config load it itself."
end

require 'configatron'
configatron.lock!

# The main class powering Chalk's configuration.
#
# This is written using a wrapped Singleton, which makes testing
# possible (just stub `Chalk::Config.instance` to return a fresh
# instance) and helps hide implementation.
class Chalk::Config
  include Singleton

  # Sets the current environment. All configuration is then reapplied
  # in the order it was {.register}ed. This means you don't have to
  # worry about setting your environment prior to registering config
  # files.
  #
  # @return [String] The current environment.
  def self.environment=(name)
    instance.send(:environment=, name)
  end

  # You should generally not take any action directly off this
  # value. All codepath switches should be triggered off configuration
  # keys, possibly with environment assertions to ensure safety.
  #
  # @return [String] The current environment (default: `'default'`)
  def self.environment
    instance.send(:environment)
  end

  # Specify the list of environments every configuration file must
  # include.
  #
  # It's generally recommended to set this in a wrapper library, and
  # use that wrapper library in all your projects. This way you can be
  # defensive, and have certainty no config file slips through without
  # the requisite environment keys.
  #
  # @param environments [Enumerable<String>] The list of required environments.
  def self.required_environments=(environments)
    instance.send(:required_environments=, environments)
  end

  # Access the environments registered by {.required_environments=}.
  #
  # @return [Enumerable] The registered environments list (by default, nil)
  def self.required_environments
    instance.send(:required_environments)
  end

  # Register a given YAML file to be included in the global
  # configuration.
  #
  # The config will be loaded once (cached in memory) and be
  # immediately deep-merged onto configatron. If you later run
  # {.environment=}, then all registered configs will be reapplied in
  # the order they were loaded.
  #
  # So for example, running
  # `Chalk::Config.register('/path/to/config.yaml')` for a file with
  # contents:
  #
  # ```yaml
  # env1:
  #   key1: value1
  #   key2: value2
  # ```
  #
  # would yield `configatron.env1.key1 == value1`,
  # `configatron.env1.key2 == value2`. Later registering a file with
  # contents:
  #
  # ```yaml
  # env1:
  #   key1: value3
  # ```
  #
  # would yield `configatron.env1.key1 == value3`,
  # `configatron.env1.key2 == value2`.
  #
  # @param filepath [String] Absolute path to the config file
  # @option options [Boolean] :optional If true, it's fine for the
  #   file to be missing, in which case this registration is
  #   discarded.
  # @option options [Boolean] :raw If true, the file doesn't have
  #  environment keys and should be splatted onto configatron
  #  directly. Otherwise, grab just the config under the appropriate
  #  environment key.
  # @option options [String] :nested What key to namespace all of
  #  this configuration under. (So `nested: 'foo'` would result in
  #  configuration available under `configatron.foo.*`.)
  def self.register(filepath, options={})
    unless filepath.start_with?('/')
      raise ArgumentError.new("Register only accepts absolute paths, not #{filepath.inspect}. (This ensures that config is always correctly loaded rather than depending on your current directory. To avoid this error in the future, you may want to use a wrapper that expands paths based on a base directory.)")
    end
    instance.send(:register, filepath, options)
  end

  # Reload a single pre-registered configuration file from disk.
  #
  # {.register} must have already been called to register
  # `filepath`. Re-reads `filepath` from disk, and updates
  # configuration to reflect the new contents.
  #
  # In the event of any error (e.g. `filepath` has been deleted, or
  # contains invalid YAML), this method will raise the underlying
  # exception and leave configuration unmodified.
  def self.reload(filepath)
    instance.send(:reload, filepath)
  end

  # Register a given raw hash to be included in the global
  # configuration.
  #
  # This allows you to specify arbitrary configuration at
  # runtime. It's generally not recommended that you use this method
  # unless your configuration really can't be encoded in config
  # files. A common example is configuration from environment
  # variables (which might be something like the name of your
  # service).
  #
  # Like {.register}, if you later run {.environment=}, this
  # configuration will be reapplied in the order it was registered.
  #
  # @param config [Hash] The raw configuration to be deep-merged into configatron.
  def self.register_raw(config)
    instance.send(:register_raw, config)
  end

  # Raises if the current environment is not one of the whitelisted
  # environments provided.
  #
  # Generally useful if you have a dev-only codepath you want to be
  # *sure* never activates in production.
  def self.assert_environment(environments)
    environments = [environments] if environments.kind_of?(String)
    return if environments.include?(environment)

    raise DisallowedEnvironment.new("Current environment #{environment.inspect} is not one of the allowed environments #{environments.inspect}")
  end

  # Raises if the current environment is one of the blacklisted
  # environments provided.
  #
  # Generally useful if you have a dev-only codepath you want to be
  # *sure* never activates in production.
  def self.assert_not_environment(environments)
    environments = [environments] if environments.kind_of?(String)
    return unless environments.include?(environment)

    raise DisallowedEnvironment.new("Current environment #{environment.inspect} is one of the disallowed environments #{environments.inspect}")
  end

  private

  def initialize
    # List of registered configs, in the form:
    #
    # file => {config: ..., options: ...}
    @registrations = []
    @registered_files = Set.new
    @environment = 'default'
  end

  ## The actual instance implementations

  # Possibly reconfigure if the environment changes.
  def environment=(name)
    @environment = name
    reapply_config
  end

  def environment
    @environment
  end

  def required_environments=(environments)
    @required_environments = environments
    @registrations.each do |registration|
      # Validate all existing config
      validate_config(registration)
    end
  end

  def required_environments
    @required_environments
  end

  def register(filepath, options)
    if @registered_files.include?(filepath)
      raise Error.new("You've already registered #{filepath}.")
    end
    @registered_files << filepath

    begin
      config = load!(filepath)
    rescue Errno::ENOENT
      raise unless options[:optional]
    rescue EmptyYamlFileError => e
      if options[:optional]
        puts "WARN: #{e.message} Continuing."
        config = nil
      else
        raise e
      end
    end

    register_parsed(config, filepath, options)
  end

  def reload(filepath)
    registration = @registrations.find { |r| r[:filepath] == filepath }
    unless registration
      raise ArgumentError.new("`#{filepath}' was not registered.")
    end

    begin
      config = load!(filepath)
    rescue Errno::ENOENT
      raise unless options[:optional]
    end

    validate_config(registration.merge(config: config))

    registration[:config] = config

    allow_configatron_changes do
      reapply_config
    end
  end

  def register_raw(config)
    register_parsed(config, nil, {})
  end

  private

  # Register some raw config
  def register_parsed(config, filepath, options)
    allow_configatron_changes do
      directive = {
        config: config,
        filepath: filepath,
        options: options,
      }

      validate_config(directive)
      @registrations << directive

      allow_configatron_changes do
        mixin_config(directive)
      end
    end
  end

  def allow_configatron_changes(&blk)
    configatron.unlock!

    begin
      blk.call
    ensure
      configatron.lock!
    end
  end

  def load!(filepath)
    begin
      loaded = YAML.load_file(filepath)
    rescue Psych::BadAlias => e
      # YAML parse-time errors include the filepath already, but
      # load-time errors do not.
      #
      # Specifically, `Psych::BadAlias` (raised by doing something
      # like `YAML.load('foo: *bar')`) does not:
      # https://github.com/tenderlove/psych/issues/192
      e.message << " (while loading #{filepath})"
      raise
    end
    if loaded.is_a?(FalseClass)
      raise EmptyYamlFileError.new("YAML.load(#{filepath.inspect}) parses false, which indicates that the file is empty.")
    elsif not loaded.is_a?(Hash)
      raise Error.new("YAML.load(#{filepath.inspect}) parses into a #{loaded.class}, not a Hash")
    end
    loaded
  end

  # Take a hash and mix in the environment-appropriate key to an
  # existing configatron object.
  def mixin_config(directive)
    return if directive[:options][:optional] && directive[:config].nil?

    raw = directive[:options][:raw]

    config = directive[:config]
    filepath = directive[:filepath]

    if !raw && filepath && config && !config.include?(environment)
      # Directive is derived from a file (i.e. not runtime_config)
      # with environments and that file existed, but is missing the
      # environment.
      raise MissingEnvironment.new("Current environment #{environment.inspect} not defined in config file #{directive[:filepath].inspect}. (HINT: you should have a YAML key of #{environment.inspect}. You may want to inherit a default via YAML's `<<` operator.)")
    end

    if raw
      choice = config
    elsif filepath && config
      # Derived from file, and file present
      choice = config.fetch(environment)
    elsif filepath
      # Derived from file, but file missing
      choice = {}
    else
      # Manually specified runtime_config
      choice = config
    end

    subconfigatron = configatron
    if nested = directive[:options][:nested]
      nested.split('.').each do |key|
        subconfigatron = subconfigatron[key]
      end
    end

    subconfigatron.configure_from_hash(choice)
  end

  def validate_config(directive)
    return if directive[:config].nil? && directive[:options][:optional]

    (@required_environments || []).each do |environment|
      raw = directive[:options][:raw]

      config = directive[:config]
      filepath = directive[:filepath]

      next if raw

      if filepath && config && !config.include?(environment)
        raise MissingEnvironment.new("Required environment #{environment.inspect} not defined in config file #{directive[:filepath].inspect}. (HINT: you should have a YAML key of #{environment.inspect}. You may want to inherit a default via YAML's `<<` operator.)")
      end
    end
  end

  def reapply_config
    allow_configatron_changes do
      configatron.reset!
      @registrations.each do |registration|
        mixin_config(registration)
      end
    end
  end
end
