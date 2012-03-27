require "rubygems"
require "typhoeus"

require "tar_header"

# Lists the contents of a tar file using HTTP 1.1 Range requests.
class TarIndex
  BLOCK_SIZE = 512
  BATCH_SIZE = 20

  include Enumerable

  def initialize(url)
    @url = url
    @headers = []
    @pos = 0
  end

  def bytes_read
    @pos or @full_size
  end

  def full_size
    if @full_size.nil?
      fetch_next_headers
    end
    @full_size
  end

  def each
    @headers.each do |header|
      yield header
    end
    while new_headers = fetch_next_headers
      new_headers.each do |header|
        yield header
      end
    end
  end

  private 

  def fetch_next_headers
    return nil if @pos.nil?

    errors = 0
    begin
      response = Typhoeus::Request.get(@url, :headers=>{"Range"=>"bytes=#{ @pos }-#{ @pos + (BATCH_SIZE * BLOCK_SIZE - 1) }"})
      @full_size = response.headers_hash["Content-Range"][/\/([0-9]+)$/,1].to_i
    rescue
      errors += 1
      retry if errors < 5
      raise "HTTP error."
    end

    raise "HTTP error #{ response.status }." if not response.success?

    data = response.body.to_s

    new_headers = []
    offset = 0
    while offset + BLOCK_SIZE <= data.size and not @pos.nil?
      header = TarHeader.from_string(data[offset, BLOCK_SIZE])
      if header.empty?
        @pos = nil
      else
        entry_size = BLOCK_SIZE + header.size + (BLOCK_SIZE - (header.size % BLOCK_SIZE)) % BLOCK_SIZE
        offset += entry_size
        @pos += entry_size
        @headers << header
        new_headers << header
      end
    end

    new_headers.empty? ? nil : new_headers
  end
end

