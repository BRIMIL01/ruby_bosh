require 'rest_client'
require 'builder'
require 'rexml/document'
require 'base64'
require 'hpricot'
require 'system_timer'

class RubyBOSH  
  BOSH_XMLNS    = 'http://jabber.org/protocol/httpbind'
  TLS_XMLNS     = 'urn:ietf:params:xml:ns:xmpp-tls'
  SASL_XMLNS    = 'urn:ietf:params:xml:ns:xmpp-sasl'
  BIND_XMLNS    = 'urn:ietf:params:xml:ns:xmpp-bind'
  SESSION_XMLNS = 'urn:ietf:params:xml:ns:xmpp-session'

  class Timeout < StandardError; end
  class AuthFailed < StandardError; end

  attr_accessor :jid, :rid, :sid, :success
  def initialize(jid, pw, service_url, opts={}) 
    @service_url = service_url
    @jid, @pw = jid, pw
    @host = jid.split("@").last
    @success = false
    @timeout = opts[:timeout] || 3 #seconds 
    @headers = {"Content-Type" => "text/xml; charset=utf-8",
                "Accept" => "text/xml"}
  end

  def success?
    @success == true
  end

  def self.initialize_session(*args)
    new(*args).connect
  end

  def connect
    initialize_bosh_session
    if send_auth_request 
      send_restart_request
      request_resource_binding
      @success = send_session_request
    end

    raise RubyBOSH::AuthFailed, "could not authenticate #{@jid}" unless success?
    @rid += 1 #updates the rid for the next call from the browser
    
    [@jid, @sid, @rid]
  end

  private
  def initialize_bosh_session 
    response = deliver(construct_body(:wait => 5, :to => @host,
                                      :hold => 3, :window => 5,
                                      "xmpp:version" => '1.0'))
    parse(response)
  end

  def construct_body(params={}, &block)
    @rid ? @rid+=1 : @rid=rand(100000)

    builder = Builder::XmlMarkup.new
    parameters = {:rid => @rid, :xmlns => BOSH_XMLNS}.merge(params)

    if block_given?
      builder.body(parameters) {|body| yield(body)}
    else
      builder.body(parameters)
    end
  end

  def send_auth_request 
    request = construct_body(:sid => @sid) do |body|
      auth_string = "#{@jid}\x00#{@jid.split("@").first.strip}\x00#{@pw}" 
      body.auth(Base64.encode64(auth_string).gsub(/\s/,''), 
                    :xmlns => SASL_XMLNS, :mechanism => 'PLAIN')
    end

    response = deliver(request)
    response.include?("success")
  end

  def send_restart_request
    request = construct_body(:sid => @sid, "xmpp:restart" => true, "xmlns:xmpp" => 'urn:xmpp:xbosh')
    deliver(request).include?("stream:features")
  end

  def request_resource_binding
    request = construct_body(:sid => @sid) do |body|
      body.iq(:id => "bind_#{rand(100000)}", :type => "set", 
              :xmlns => "jabber:client") do |iq|
        iq.bind(:xmlns => BIND_XMLNS) do |bind|
          bind.resource('presently')
        end
      end
    end
    
    response = deliver(request)
    response.include?("<jid>") 
  end

  def send_session_request
    request = construct_body(:sid => @sid) do |body|
      body.iq(:xmlns => "jabber:client", :type => "set",
              :id => "sess_#{rand(100000)}") do |iq|
        iq.session(:xmlns => SESSION_XMLNS)
      end 
    end

    response = deliver(request)
    response.include?("body") 
  end

  def parse(_response)
    doc = Hpricot(_response)
    doc.search("//body").each do |body|
      @sid = body.attributes["sid"].to_s
    end
    _response
  end

  def deliver(xml)
    SystemTimer.timeout(@timeout) do 
      send(xml)
      recv(RestClient.post(@service_url, xml, @headers))
    end
  rescue SystemTimer::Error => e
    raise RubyBOSHClient::Timeout, e.message
  end

  def send(msg)
    puts "Ruby-BOSH - SEND\n#{msg}"; msg
  end

  def recv(msg)
    puts "Ruby-BOSH - RECV\n#{msg}"; msg
  end
end


if __FILE__ == $0
  p RubyBOSH.initialize_session(ARGV[0], ARGV[1], 
      "http://localhost:5280/http-bind")
end
