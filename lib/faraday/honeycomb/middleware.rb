require 'faraday'
require 'libhoney'
require 'securerandom'

require 'faraday/honeycomb/version'

module Faraday
  module Honeycomb
    USER_AGENT_SUFFIX = "#{GEM_NAME}/#{VERSION}"

    class Middleware
      def initialize(app, options = {})
        honeycomb = options[:client] || Libhoney::Client.new(options.merge(user_agent_addition: USER_AGENT_SUFFIX))
        @builder = honeycomb.builder.
          add(
            'type' => 'http_client',
            'meta.package' => 'faraday',
            'meta.package_version' => Faraday::VERSION,
          )
        @app = app
      end

      def call(env)
        event = @builder.event

        add_request_fields(event, env)

        start = Time.now
        response = adding_span_metadata_if_available(event, env) do
          @app.call(env)
        end

        add_response_fields(event, response)

        response
      rescue Exception => e
        if event
          event.add_field 'request.error', e.class.name
          event.add_field 'request.error_detail', e.message
        end
        raise
      ensure
        if start && event
          finish = Time.now
          duration = finish - start
          event.add_field 'duration_ms', duration * 1000
          event.send
        end
      end

      private
      def add_request_fields(event, env)
        loud_method = env.method.upcase.to_s

        event.add(
          'name' => "#{loud_method} #{env.url.host}#{env.url.path}",
          'request.method' => loud_method,
          'request.protocol' => env.url.scheme,
          'request.host' => env.url.host,
          'request.path' => env.url.path,
        )
      end

      def add_response_fields(event, response)
        event.add_field 'response.status_code', response.status
      end

      def adding_span_metadata_if_available(event, env)
        return yield unless defined?(::Honeycomb.trace_id)

        trace_id = ::Honeycomb.trace_id
        name = "#{env.method} #{env.url.path}"

        event.add_field :traceId, trace_id if trace_id
        span_id = SecureRandom.uuid
        event.add_field :id, span_id
        event.add_field :serviceName, 'faraday'
        event.add_field :name, name if name

        ::Honeycomb.with_span_id(span_id) do |parent_span_id|
          event.add_field :parentId, parent_span_id
          yield
        end
      end
    end
  end
end
