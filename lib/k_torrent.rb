require 'net/http'
require 'digest/sha1'
require 'cgi'
require 'forwardable'
require 'fileutils'
require 'thread'
require 'logger'

module KTorrent
  extend self

  def log(message)
    @log_file ||= Logger.new('log.txt')
    @log_file.info(message)
  end

  def debug(message)
    @log_file ||= Logger.new('log.txt')
    @log_file.debug(message)
  end

  def download_dir
    @download_dir ||= 'downloads'
  end

  def download_dir=(d)
    @download_dir = d || 'downloads'
  end
end

# Functionality
require 'k_torrent/b_encoding'
require 'k_torrent/torrent'
require 'k_torrent/manager'
