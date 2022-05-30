require 'vcr'

VCR.configure do |config|
  config.cassette_library_dir = 'test/fixtures/vcr_cassettes'
  config.hook_into :faraday

  config.default_cassette_options = { match_requests_on: %i[method uri] }

  config.filter_sensitive_data('PLACEHOLDER_API_KEY') { ENV['MAILOSAUR_API_KEY'] }

  # Filter out the basic authorization header from requests
  config.filter_sensitive_data('PLACEHOLDER_AUTHORIZATION') do |interaction|
    next unless interaction.request.headers['Authorization']

    interaction.request.headers['Authorization'][0]
  end
end
