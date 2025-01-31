require 'uri'

module Mailosaur
  class Messages
    #
    # Creates and initializes a new instance of the Messages class.
    # @param client connection.
    #
    def initialize(conn, handle_http_error)
      @conn = conn
      @handle_http_error = handle_http_error
    end

    # @return [Connection] the client connection.
    attr_reader :conn

    #
    # Retrieve a message using search criteria
    #
    # Returns as soon as a message matching the specified search criteria is
    # found. This is the most efficient method of looking up a message.
    #
    # @param server [String] The identifier of the server hosting the message.
    # @param criteria [SearchCriteria] The search criteria to use in order to find
    # a match.
    # @param timeout [Integer] Specify how long to wait for a matching result
    # (in milliseconds).
    # @param received_after [DateTime] Limits results to only messages received
    # after this date/time.
    #
    # @return [Message] operation results.
    #
    def get(server, criteria, timeout: 10_000, received_after: DateTime.now - (1.0 / 24))
      # Defaults timeout to 10s, receivedAfter to 1h
      raise Mailosaur::MailosaurError.new('Must provide a valid Server ID.', 'invalid_request') if server.length != 8

      result = search(server, criteria, page: 0, items_per_page: 1, timeout: timeout, received_after: received_after)
      get_by_id(result.items[0].id)
    end

    #
    # Retrieve a message
    #
    # Retrieves the detail for a single email message. Simply supply the unique
    # identifier for the required message.
    #
    # @param id The identifier of the email message to be retrieved.
    #
    # @return [Message] operation results.
    #
    def get_by_id(id)
      response = conn.get "api/messages/#{id}"
      @handle_http_error.call(response) unless response.status == 200
      model = JSON.parse(response.body)
      Mailosaur::Models::Message.new(model)
    end

    #
    # Delete a message
    #
    # Permanently deletes a message. This operation cannot be undone. Also deletes
    # any attachments related to the message.
    #
    # @param id The identifier of the message to be deleted.
    #
    def delete(id)
      response = conn.delete "api/messages/#{id}"
      @handle_http_error.call(response) unless response.status == 204
      nil
    end

    #
    # List all messages
    #
    # Returns a list of your messages in summary form. The summaries are returned
    # sorted by received date, with the most recently-received messages appearing
    # first.
    #
    # @param server [String] The identifier of the server hosting the messages.
    # @param page [Integer] Used in conjunction with `itemsPerPage` to support
    # pagination.
    # @param items_per_page [Integer] A limit on the number of results to be
    # returned per page. Can be set between 1 and 1000 items, the default is 50.
    # @param received_after [DateTime] Limits results to only messages received
    # after this date/time.
    #
    # @return [MessageListResult] operation results.
    #
    def list(server, page: nil, items_per_page: nil, received_after: nil)
      url = "api/messages?server=#{server}"
      url += page ? "&page=#{page}" : ''
      url += items_per_page ? "&itemsPerPage=#{items_per_page}" : ''
      url += received_after ? "&receivedAfter=#{CGI.escape(received_after.iso8601)}" : ''

      response = conn.get url

      @handle_http_error.call(response) unless response.status == 200

      model = JSON.parse(response.body)
      Mailosaur::Models::MessageListResult.new(model)
    end

    #
    # Delete all messages
    #
    # Permanently deletes all messages held by the specified server. This operation
    # cannot be undone. Also deletes any attachments related to each message.
    #
    # @param server [String] The identifier of the server to be emptied.
    #
    def delete_all(server)
      response = conn.delete "api/messages?server=#{server}"
      @handle_http_error.call(response) unless response.status == 204
      nil
    end

    #
    # Search for messages
    #
    # Returns a list of messages matching the specified search criteria, in summary
    # form. The messages are returned sorted by received date, with the most
    # recently-received messages appearing first.
    #
    # @param server [String] The identifier of the server hosting the messages.
    # @param criteria [SearchCriteria] The search criteria to match results
    # against.
    # @param page [Integer] Used in conjunction with `itemsPerPage` to support
    # pagination.
    # @param items_per_page [Integer] A limit on the number of results to be
    # returned per page. Can be set between 1 and 1000 items, the default is 50.
    # @param timeout [Integer] Specify how long to wait for a matching result
    # (in milliseconds).
    # @param received_after [DateTime] Limits results to only messages received
    # after this date/time.
    # @param error_on_timeout [Boolean] When set to false, an error will not be
    # throw if timeout is reached (default: true).
    #
    # @return [MessageListResult] operation results.
    #
    def search(server, criteria, page: nil, items_per_page: nil, timeout: nil, received_after: nil, error_on_timeout: true) # rubocop:disable all
      url = "api/messages/search?server=#{server}"
      url += page ? "&page=#{page}" : ''
      url += items_per_page ? "&itemsPerPage=#{items_per_page}" : ''
      url += received_after ? "&receivedAfter=#{CGI.escape(received_after.iso8601)}" : ''

      poll_count = 0
      start_time = Time.now.to_f

      loop do
        response = conn.post url, criteria.to_json

        @handle_http_error.call(response) unless response.status == 200

        model = JSON.parse(response.body)
        return Mailosaur::Models::MessageListResult.new(model) if timeout.to_i.zero? || !model['items'].empty?

        delay_pattern = (response.headers['x-ms-delay'] || '1000').split(',').map(&:to_i)

        delay = poll_count >= delay_pattern.length ? delay_pattern[delay_pattern.length - 1] : delay_pattern[poll_count]

        poll_count += 1

        ## Stop if timeout will be exceeded
        if ((1000 * (Time.now.to_f - start_time).to_i) + delay) > timeout
          return Mailosaur::Models::MessageListResult.new(model) unless error_on_timeout

          raise Mailosaur::MailosaurError.new('No matching messages found in time. By default, only messages received in the last hour are checked (use receivedAfter to override this).', 'search_timeout')
        end

        sleep(delay / 1000)
      end
    end

    #
    # Create a message.
    #
    # Creates a new message that can be sent to a verified email address. This is
    # useful in scenarios where you want an email to trigger a workflow in your
    # product
    #
    # @param server [String] The identifier of the server to create the message in.
    # @param options [MessageCreateOptions] The options with which to create the message.
    #
    # @return [Message] operation result.
    #
    def create(server, message_create_options)
      response = conn.post "api/messages?server=#{server}", message_create_options.to_json
      @handle_http_error.call(response) unless response.status == 200
      model = JSON.parse(response.body)
      Mailosaur::Models::Message.new(model)
    end

    #
    # Forward an email.
    #
    # Forwards the specified email to a verified email address.
    #
    # @param id [String] The identifier of the email to forward.
    # @param options [MessageForwardOptions] The options with which to forward the email.
    # against.
    #
    # @return [Message] operation result.
    #
    def forward(id, message_forward_options)
      response = conn.post "api/messages/#{id}/forward", message_forward_options.to_json
      @handle_http_error.call(response) unless response.status == 200
      model = JSON.parse(response.body)
      Mailosaur::Models::Message.new(model)
    end

    #
    # Reply to an email.
    #
    # Sends a reply to the specified email. This is useful for when simulating a user
    # replying to one of your emails.
    #
    # @param id [String] The identifier of the email to reply to.
    # @param options [MessageReplyOptions] The options with which to reply to the email.
    # against.
    #
    # @return [Message] operation result.
    #
    def reply(id, message_reply_options)
      response = conn.post "api/messages/#{id}/reply", message_reply_options.to_json
      @handle_http_error.call(response) unless response.status == 200
      model = JSON.parse(response.body)
      Mailosaur::Models::Message.new(model)
    end
  end
end
