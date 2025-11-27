#!/usr/bin/ruby
#
# Copyright Istio Authors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

require 'webrick'
require 'json'
require 'net/http'
# HACKED: gRPC server runtime + generated stubs
require 'grpc'
require_relative 'details_services_pb'
require 'grpc/reflection'
require 'grpc/reflection/v1alpha/reflection_pb'

if ARGV.length < 1 then
    puts "usage: #{$PROGRAM_NAME} port"
    exit(-1)
end

port = Integer(ARGV[0])
# HACKED: allow gRPC/HTTP to be toggled independently at runtime.
grpc_port = ENV.fetch('GRPC_PORT', '50051').to_i
enable_grpc = ENV.fetch('ENABLE_GRPC', 'true').downcase == 'true'
enable_http = ENV.fetch('ENABLE_HTTP', 'false').downcase == 'true'

server = nil
if enable_http
  server = WEBrick::HTTPServer.new(
      :BindAddress => '*',
      :Port => port,
      :AcceptCallback => -> (s) { s.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) },
  )
  trap 'INT' do server.shutdown end
end

# HACKED: gRPC service reuses the same business logic to keep changes small.
class DetailsServiceImpl < Details::DetailsService::Service
  def get_details(req, _call)
    details = get_book_details(req.id.to_i, {})
    Details::DetailsResponse.new(
      id: details['id'].to_s,
      author: details[:author],
      year: details[:year],
      type: details[:type],
      pages: details[:pages],
      publisher: details[:publisher],
      language: details[:language],
      isbn10: details['ISBN-10'],
      isbn13: details['ISBN-13']
    )
  end
end

if enable_http
  server.mount_proc '/health' do |req, res|
      res.status = 200
      res.body = {'status' => 'Details is healthy'}.to_json
      res['Content-Type'] = 'application/json'
  end

  server.mount_proc '/details' do |req, res|
      pathParts = req.path.split('/')
      headers = get_forward_headers(req)

      begin
          begin
            id = Integer(pathParts[-1])
          rescue
            raise 'please provide numeric product id'
          end
          details = get_book_details(id, headers)
          res.body = details.to_json
          res['Content-Type'] = 'application/json'
      rescue => error
          res.body = {'error' => error}.to_json
          res['Content-Type'] = 'application/json'
          res.status = 400
      end
  end
end

# TODO: provide details on different books.
def get_book_details(id, headers)
    if ENV['ENABLE_EXTERNAL_BOOK_SERVICE'] === 'true' then
      # the ISBN of one of Comedy of Errors on the Amazon
      # that has Shakespeare as the single author
        isbn = '0486424618'
        return fetch_details_from_external_service(isbn, id, headers)
    end

    return {
        'id' => id,
        'author': 'William Shakespeare',
        'year': 1595,
        'type' => 'paperback',
        'pages' => 200,
        'publisher' => 'PublisherA',
        'language' => 'English',
        'ISBN-10' => '1234567890',
        'ISBN-13' => '123-1234567890'
    }
end

def fetch_details_from_external_service(isbn, id, headers)
    uri = URI.parse('https://www.googleapis.com/books/v1/volumes?q=isbn:' + isbn)
    http = Net::HTTP.new(uri.host, ENV['DO_NOT_ENCRYPT'] === 'true' ? 80:443)
    http.read_timeout = 5 # seconds

    # DO_NOT_ENCRYPT is used to configure the details service to use either
    # HTTP (true) or HTTPS (false, default) when calling the external service to
    # retrieve the book information.
    #
    # Unless this environment variable is set to true, the app will use TLS (HTTPS)
    # to access external services.
    unless ENV['DO_NOT_ENCRYPT'] === 'true' then
      http.use_ssl = true
    end

    request = Net::HTTP::Get.new(uri.request_uri)
    headers.each { |header, value| request[header] = value }

    response = http.request(request)

    json = JSON.parse(response.body)
    book = json['items'][0]['volumeInfo']

    language = book['language'] === 'en'? 'English' : 'unknown'
    type = book['printType'] === 'BOOK'? 'paperback' : 'unknown'
    isbn10 = get_isbn(book, 'ISBN_10')
    isbn13 = get_isbn(book, 'ISBN_13')

    return {
        'id' => id,
        'author': book['authors'][0],
        'year': book['publishedDate'],
        'type' => type,
        'pages' => book['pageCount'],
        'publisher' => book['publisher'],
        'language' => language,
        'ISBN-10' => isbn10,
        'ISBN-13' => isbn13
  }

end

def get_isbn(book, isbn_type)
  isbn_dentifiers = book['industryIdentifiers'].select do |identifier|
    identifier['type'] === isbn_type
  end

  return isbn_dentifiers[0]['identifier']
end

def get_forward_headers(request)
  headers = {}

  # Keep this in sync with the headers in productpage and reviews.
  incoming_headers = [
      # All applications should propagate x-request-id. This header is
      # included in access log statements and is used for consistent trace
      # sampling and log sampling decisions in Istio.
      'x-request-id',

      # Lightstep tracing header. Propagate this if you use lightstep tracing
      # in Istio (see
      # https://istio.io/latest/docs/tasks/observability/distributed-tracing/lightstep/)
      # Note: this should probably be changed to use B3 or W3C TRACE_CONTEXT.
      # Lightstep recommends using B3 or TRACE_CONTEXT and most application
      # libraries from lightstep do not support x-ot-span-context.
      'x-ot-span-context',

      # Datadog tracing header. Propagate these headers if you use Datadog
      # tracing.
      'x-datadog-trace-id',
      'x-datadog-parent-id',
      'x-datadog-sampling-priority',

      # W3C Trace Context. Compatible with OpenCensusAgent and Stackdriver Istio
      # configurations.
      'traceparent',
      'tracestate',

      # Cloud trace context. Compatible with OpenCensusAgent and Stackdriver Istio
      # configurations.
      'x-cloud-trace-context',

      # Grpc binary trace context. Compatible with OpenCensusAgent nad
      # Stackdriver Istio configurations.
      'grpc-trace-bin',

      # b3 trace headers. Compatible with Zipkin, OpenCensusAgent, and
      # Stackdriver Istio configurations.
      'x-b3-traceid',
      'x-b3-spanid',
      'x-b3-parentspanid',
      'x-b3-sampled',
      'x-b3-flags',

      # SkyWalking trace headers.
      'sw8',

      # Application-specific headers to forward.
      'end-user',
      'user-agent',

      # Context and session specific headers
      'cookie',
      'authorization',
      'jwt'
  ]

  request.each do |header, value|
    if incoming_headers.include? header then
      headers[header] = value
    end
  end

  return headers
end

# HACKED: start gRPC server in a background thread so HTTP flow remains unchanged.
if enable_grpc
  grpc_server = GRPC::RpcServer.new
  grpc_server.add_http2_port("0.0.0.0:#{grpc_port}", :this_port_is_insecure)
  grpc_server.handle(DetailsServiceImpl.new)
  # Enable server reflection for grpcurl/grpc_cli
  grpc_server.handle(GRPC::Reflection::V1alpha::ServerReflection::Service)
  if enable_http
    Thread.new { grpc_server.run_till_terminated }
  else
    # If HTTP is disabled, block on gRPC so the container stays up.
    grpc_server.run_till_terminated
    exit 0
  end
end

server.start if enable_http
