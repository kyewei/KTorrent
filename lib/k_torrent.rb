require 'net/http'
require 'digest/sha1'
require 'cgi'
require 'forwardable'
require 'fileutils'

module KTorrent
  extend self

  def logger
    @logger ||= $stdout
  end

  def logger=(l)
    @logger = l || $stdout
  end

  def debugger
    @debug ||= $stdderr
  end

  def debugger=(d)
    @logger = l || $stdderr
  end

  def debug_on
    @debug_on ||= false
  end

  def debug_on=(d)
    @debug_on = d || false
  end

  def log(message)
    logger.write(message + "\n")
  end

  def debug(message)
    debugger.write(message + "\n") if debug_on
  end

  def download_dir
    @download_dir ||= 'downloads/'
  end

  def download_dir=(d)
    @download_dir = d || 'downloads/'
  end

  # def self.parse_magnet_url(url)
  #   scheme, params = url.split('?', 2)
  #   decoded_params = URI.decode_www_form(URI.decode(params)).to_h
  # end
end

# Functionality
require 'k_torrent/b_encoding'
require 'k_torrent/torrent'
require 'k_torrent/manager'
