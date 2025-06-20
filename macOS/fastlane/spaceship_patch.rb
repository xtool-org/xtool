require "spaceship"

# the ASC API has started (June 2025) throwing a fit when it
# sees DEVELOPER_ID_APPLICATION_G2 in the certificate types filter.
# so we patch Spaceship to filter locally instead of via the API.
# c.f. https://github.com/fastlane/fastlane/pull/29588

class << Spaceship::ConnectAPI::Certificate
  alias_method :orig, :all

  def all(**args)
    types = args[:filter]&.delete(:certificateType)&.split(",")
    certs = orig(**args)
    types ? certs.select { |cert| types.include?(cert.certificate_type) } : certs
  end
end
