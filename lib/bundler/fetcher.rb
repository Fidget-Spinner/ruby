# frozen_string_literal: true

require_relative "vendored_persistent"
require_relative "vendored_timeout"
require_relative "vendored_securerandom"
require "zlib"

module Bundler
  # Handles all the fetching with the rubygems server
  class Fetcher
    autoload :Base, File.expand_path("fetcher/base", __dir__)
    autoload :CompactIndex, File.expand_path("fetcher/compact_index", __dir__)
    autoload :Downloader, File.expand_path("fetcher/downloader", __dir__)
    autoload :Dependency, File.expand_path("fetcher/dependency", __dir__)
    autoload :Index, File.expand_path("fetcher/index", __dir__)

    # This error is raised when it looks like the network is down
    class NetworkDownError < HTTPError; end
    # This error is raised if we should rate limit our requests to the API
    class TooManyRequestsError < HTTPError; end
    # This error is raised if the API returns a 413 (only printed in verbose)
    class FallbackError < HTTPError; end

    # This is the error raised if OpenSSL fails the cert verification
    class CertificateFailureError < HTTPError
      def initialize(remote_uri)
        remote_uri = filter_uri(remote_uri)
        super "Could not verify the SSL certificate for #{remote_uri}.\nThere" \
          " is a chance you are experiencing a man-in-the-middle attack, but" \
          " most likely your system doesn't have the CA certificates needed" \
          " for verification. For information about OpenSSL certificates, see" \
          " https://railsapps.github.io/openssl-certificate-verify-failed.html."
      end
    end

    # This is the error raised when a source is HTTPS and OpenSSL didn't load
    class SSLError < HTTPError
      def initialize(msg = nil)
        super "Could not load OpenSSL.\n" \
          "You must recompile Ruby with OpenSSL support.\n" \
          "original error: #{msg}\n"
      end
    end

    # This error is raised if HTTP authentication is required, but not provided.
    class AuthenticationRequiredError < HTTPError
      def initialize(remote_uri)
        remote_uri = filter_uri(remote_uri)
        super "Authentication is required for #{remote_uri}.\n" \
          "Please supply credentials for this source. You can do this by running:\n" \
          "`bundle config set --global #{remote_uri} username:password`\n" \
          "or by storing the credentials in the `#{Settings.key_for(remote_uri)}` environment variable"
      end
    end

    # This error is raised if HTTP authentication is provided, but incorrect.
    class BadAuthenticationError < HTTPError
      def initialize(remote_uri)
        remote_uri = filter_uri(remote_uri)
        super "Bad username or password for #{remote_uri}.\n" \
          "Please double-check your credentials and correct them."
      end
    end

    # This error is raised if HTTP authentication is correct, but lacks
    # necessary permissions.
    class AuthenticationForbiddenError < HTTPError
      def initialize(remote_uri)
        remote_uri = filter_uri(remote_uri)
        super "Access token could not be authenticated for #{remote_uri}.\n" \
          "Make sure it's valid and has the necessary scopes configured."
      end
    end

    HTTP_ERRORS = (Downloader::HTTP_RETRYABLE_ERRORS + Downloader::HTTP_NON_RETRYABLE_ERRORS).freeze
    deprecate_constant :HTTP_ERRORS

    NET_ERRORS = [
      :HTTPBadGateway,
      :HTTPBadRequest,
      :HTTPFailedDependency,
      :HTTPForbidden,
      :HTTPInsufficientStorage,
      :HTTPMethodNotAllowed,
      :HTTPMovedPermanently,
      :HTTPNoContent,
      :HTTPNotFound,
      :HTTPNotImplemented,
      :HTTPPreconditionFailed,
      :HTTPRequestEntityTooLarge,
      :HTTPRequestURITooLong,
      :HTTPUnauthorized,
      :HTTPUnprocessableEntity,
      :HTTPUnsupportedMediaType,
      :HTTPVersionNotSupported,
    ].freeze
    deprecate_constant :NET_ERRORS

    # Exceptions classes that should bypass retry attempts. If your password didn't work the
    # first time, it's not going to the third time.
    FAIL_ERRORS = [
      AuthenticationRequiredError,
      BadAuthenticationError,
      AuthenticationForbiddenError,
      FallbackError,
      SecurityError,
      Gem::Requirement::BadRequirementError,
      Gem::Net::HTTPBadGateway,
      Gem::Net::HTTPBadRequest,
      Gem::Net::HTTPFailedDependency,
      Gem::Net::HTTPForbidden,
      Gem::Net::HTTPInsufficientStorage,
      Gem::Net::HTTPMethodNotAllowed,
      Gem::Net::HTTPMovedPermanently,
      Gem::Net::HTTPNoContent,
      Gem::Net::HTTPNotFound,
      Gem::Net::HTTPNotImplemented,
      Gem::Net::HTTPPreconditionFailed,
      Gem::Net::HTTPRequestEntityTooLarge,
      Gem::Net::HTTPRequestURITooLong,
      Gem::Net::HTTPUnauthorized,
      Gem::Net::HTTPUnprocessableEntity,
      Gem::Net::HTTPUnsupportedMediaType,
      Gem::Net::HTTPVersionNotSupported,
    ].freeze

    class << self
      attr_accessor :disable_endpoint, :api_timeout, :redirect_limit, :max_retries
    end

    self.redirect_limit = Bundler.settings[:redirect] # How many redirects to allow in one request
    self.api_timeout    = Bundler.settings[:timeout] # How long to wait for each API call
    self.max_retries    = Bundler.settings[:retry] # How many retries for the API call

    def initialize(remote)
      @cis = nil
      @remote = remote

      Socket.do_not_reverse_lookup = true
      connection # create persistent connection
    end

    def uri
      @remote.anonymized_uri
    end

    # fetch a gem specification
    def fetch_spec(spec)
      spec -= [nil, "ruby", ""]
      spec_file_name = "#{spec.join "-"}.gemspec"

      uri = Gem::URI.parse("#{remote_uri}#{Gem::MARSHAL_SPEC_DIR}#{spec_file_name}.rz")
      spec = if uri.scheme == "file"
        path = Gem::Util.correct_for_windows_path(uri.path)
        Bundler.safe_load_marshal Bundler.rubygems.inflate(Gem.read_binary(path))
      elsif cached_spec_path = gemspec_cached_path(spec_file_name)
        Bundler.load_gemspec(cached_spec_path)
      else
        Bundler.safe_load_marshal Bundler.rubygems.inflate(downloader.fetch(uri).body)
      end
      raise MarshalError, "is #{spec.inspect}" unless spec.is_a?(Gem::Specification)
      spec
    rescue MarshalError
      raise HTTPError, "Gemspec #{spec} contained invalid data.\n" \
        "Your network or your gem server is probably having issues right now."
    end

    # return the specs in the bundler format as an index with retries
    def specs_with_retry(gem_names, source)
      Bundler::Retry.new("fetcher", FAIL_ERRORS).attempts do
        specs(gem_names, source)
      end
    end

    # return the specs in the bundler format as an index
    def specs(gem_names, source)
      index = Bundler::Index.new

      fetch_specs(gem_names).each do |name, version, platform, dependencies, metadata|
        spec = if dependencies
          EndpointSpecification.new(name, version, platform, self, dependencies, metadata).tap do |es|
            source.checksum_store.replace(es, es.checksum)
          end
        else
          RemoteSpecification.new(name, version, platform, self)
        end
        spec.source = source
        spec.remote = @remote
        index << spec
      end

      index
    rescue CertificateFailureError
      Bundler.ui.info "" if gem_names && api_fetcher? # newline after dots
      raise
    end

    def user_agent
      @user_agent ||= begin
        ruby = Bundler::RubyVersion.system

        agent = String.new("bundler/#{Bundler::VERSION}")
        agent << " rubygems/#{Gem::VERSION}"
        agent << " ruby/#{ruby.versions_string(ruby.versions)}"
        agent << " (#{ruby.host})"
        agent << " command/#{ARGV.first}"

        if ruby.engine != "ruby"
          # engine_version raises on unknown engines
          engine_version = begin
                             ruby.engine_versions
                           rescue RuntimeError
                             "???"
                           end
          agent << " #{ruby.engine}/#{ruby.versions_string(engine_version)}"
        end

        agent << " options/#{Bundler.settings.all.join(",")}"

        agent << " ci/#{cis.join(",")}" if cis.any?

        # add a random ID so we can consolidate runs server-side
        agent << " " << Gem::SecureRandom.hex(8)

        # add any user agent strings set in the config
        extra_ua = Bundler.settings[:user_agent]
        agent << " " << extra_ua if extra_ua

        agent
      end
    end

    def http_proxy
      return unless uri = connection.proxy_uri
      uri.to_s
    end

    def inspect
      "#<#{self.class}:0x#{object_id} uri=#{uri}>"
    end

    def api_fetcher?
      fetchers.first.api_fetcher?
    end

    def gem_remote_fetcher
      @gem_remote_fetcher ||= begin
        require_relative "fetcher/gem_remote_fetcher"
        fetcher = GemRemoteFetcher.new Gem.configuration[:http_proxy]
        fetcher.headers["User-Agent"] = user_agent
        fetcher.headers["X-Gemfile-Source"] = @remote.original_uri.to_s if @remote.original_uri
        fetcher
      end
    end

    private

    def available_fetchers
      if Bundler::Fetcher.disable_endpoint
        [Index]
      elsif remote_uri.scheme == "file"
        Bundler.ui.debug("Using a local server, bundler won't use the CompactIndex API")
        [Index]
      else
        [CompactIndex, Dependency, Index]
      end
    end

    def fetchers
      @fetchers ||= available_fetchers.map {|f| f.new(downloader, @remote, uri, gem_remote_fetcher) }.drop_while {|f| !f.available? }
    end

    def fetch_specs(gem_names)
      fetchers.reject!(&:api_fetcher?) unless gem_names
      fetchers.reject! do |f|
        specs = f.specs(gem_names)
        return specs if specs
        true
      end
      []
    end

    def cis
      @cis ||= Bundler::CIDetector.ci_strings
    end

    def connection
      @connection ||= begin
        needs_ssl = remote_uri.scheme == "https" ||
                    Bundler.settings[:ssl_verify_mode] ||
                    Bundler.settings[:ssl_client_cert]
        if needs_ssl
          begin
            require "openssl"
          rescue StandardError, LoadError => e
            raise SSLError.new(e.message)
          end
        end

        con = Gem::Net::HTTP::Persistent.new name: "bundler", proxy: :ENV
        if gem_proxy = Gem.configuration[:http_proxy]
          con.proxy = Gem::URI.parse(gem_proxy) if gem_proxy != :no_proxy
        end

        if remote_uri.scheme == "https"
          con.verify_mode = (Bundler.settings[:ssl_verify_mode] ||
            OpenSSL::SSL::VERIFY_PEER)
          con.cert_store = bundler_cert_store
        end

        ssl_client_cert = Bundler.settings[:ssl_client_cert] ||
                          (Gem.configuration.ssl_client_cert if
                            Gem.configuration.respond_to?(:ssl_client_cert))
        if ssl_client_cert
          pem = File.read(ssl_client_cert)
          con.cert = OpenSSL::X509::Certificate.new(pem)
          con.key  = OpenSSL::PKey::RSA.new(pem)
        end

        con.read_timeout = Fetcher.api_timeout
        con.open_timeout = Fetcher.api_timeout
        con.override_headers["User-Agent"] = user_agent
        con.override_headers["X-Gemfile-Source"] = @remote.original_uri.to_s if @remote.original_uri
        con
      end
    end

    # cached gem specification path, if one exists
    def gemspec_cached_path(spec_file_name)
      paths = Bundler.rubygems.spec_cache_dirs.map {|dir| File.join(dir, spec_file_name) }
      paths.find {|path| File.file? path }
    end

    def bundler_cert_store
      store = OpenSSL::X509::Store.new
      ssl_ca_cert = Bundler.settings[:ssl_ca_cert] ||
                    (Gem.configuration.ssl_ca_cert if
                      Gem.configuration.respond_to?(:ssl_ca_cert))
      if ssl_ca_cert
        if File.directory? ssl_ca_cert
          store.add_path ssl_ca_cert
        else
          store.add_file ssl_ca_cert
        end
      else
        store.set_default_paths
        require "rubygems/request"
        Gem::Request.get_cert_files.each {|c| store.add_file c }
      end
      store
    end

    def remote_uri
      @remote.uri
    end

    def downloader
      @downloader ||= Downloader.new(connection, self.class.redirect_limit)
    end
  end
end
