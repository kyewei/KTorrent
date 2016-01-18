require 'net/http'
require 'digest/sha1'
require 'cgi'
require 'forwardable'
require 'fileutils'
require 'thread'
require 'logger'


module KTorrent
  extend self

  def logger
    @logger ||= $stdout
  end

  def logger=(l)
    @logger = l || $stdout
  end

  def debugger
    @debug ||= $stderr
  end

  def debugger=(d)
    @logger = l || $stderr
  end

  def debug_on
    @debug_on ||= false
  end

  def debug_on=(d)
    @debug_on = d || false
  end

  def log(message)
    @previous_log ||= []
    @previous_log.shift while @previous_log.size >= 5
    @previous_log.push([Time.now, message])

    @log_file ||= Logger.new('log.txt')
    @log_file.info(message)
    # logger.write(message + "\n")
  end

  def previous_log
    @previous_log
  end

  def debug(message)
    @previous_debug ||= []
    @previous_debug.shift while @previous_debug.size >= 5
    @previous_debug.push([Time.now, message])

    @log_file ||= Logger.new('log.txt')
    @log_file.debug(message)
    # debugger.write(message + "\n") if debug_on
  end

  def previous_debug
    @previous_debug
  end

  def download_dir
    @download_dir ||= 'downloads'
  end

  def download_dir=(d)
    @download_dir = d || 'downloads'
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
