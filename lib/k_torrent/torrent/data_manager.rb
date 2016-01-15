module KTorrent
  class Torrent::DataManager
    CHUNK_SIZE = 134217728 # 128 MiB, or 128 x 1024^2
    TIME_BETWEEN_WRITES = 1 # 1 seconds
    EXIT_TIMEOUT = 3 # 3 seconds

    attr_reader :torrent, :path, :info_hash, :total_size, :piece_size, :pieces, :pieces_per_chunk, :chunks

    def initialize(torrent:)
      @torrent = torrent
      @info_hash = torrent.properties.info_hash(hex = true)
      @path = ::KTorrent.download_dir + '/' + info_hash
      FileUtils.mkdir_p(@path)

      @total_size = torrent.properties.total_size
      @piece_size = torrent.properties.piece_size

      @hashes = torrent.properties.hashes
      @pieces = torrent.properties.pieces
      @have = [false] * pieces
      @pieces_per_chunk = CHUNK_SIZE / piece_size
      @chunks = (pieces.to_f / pieces_per_chunk).ceil

      @piece = [nil] * pieces # private cache of piece bytes
      @piece_access = Mutex.new
      initialize_storage
      have_count
    end

    def initialize_storage
      if (CHUNK_SIZE < piece_size) #nope

      elsif (CHUNK_SIZE % piece_size == 0)
        chunks.times do |i|
          filename = piece_to_file(i * pieces_per_chunk)
          location = path + '/' + filename
          contents = begin # try read
            File.open(location, 'rb') { |file| file.read }
          rescue StandardError => e # No file
          end

          range_start, range_end = file_pieces(filename)

          ::KTorrent.log("Loaded file at #{location} with size #{(contents and contents.size or 'empty')}")
          if contents && contents.size == file_size(filename) # file exists, read, and matches filesize

            contents.chars.each_slice(piece_size).map(&:join).each_with_index do |piece_content, index| # group into piece_size bytes, iterate
              piece_num = file_pieces(filename).first + index
              ::KTorrent.log("#{index} #{Digest::SHA1.hexdigest(piece_content).downcase} #{@hashes[piece_num]}")

              @have[piece_num] = Digest::SHA1.hexdigest(piece_content).downcase == @hashes[piece_num] # verify files

              @piece[piece_num] = piece_content if @have[piece_num]
              #TODO: blank !@have[piece_num]
            end
          else
            File.delete(location) if File.file?(location)
            @have[range_start..range_end] = [false] * (range_end - range_start + 1)
          end
        end


      else # er what the hell

      end
    end

    def service_start(restart: false)
      return false unless @service_thread.nil? || restart
      service_stop if restart

      @buffer = Queue.new
      @service_thread = Thread.new do
        begin
          ::KTorrent.log("Data Manager has started")
          exit = false
          data = []
          until exit do
            command = @buffer.pop
            case command[0]
            when 'exit'
              exit = true
            when 'write'
              index, value = command[1]
              @piece[index] = value
              @have[index] = true
              @have_count += 1
              torrent.peers.service_commands << ['saved piece', index]
              data << command[1]
            when 'save to disk'
              unless data.empty?
                index_of_pieces_to_save = data.map { |(index, value)| piece_to_file(index)
                                             }.uniq.map { |filename| [filename, file_pieces(filename)]
                                             }.to_h

                index_of_pieces_to_save.each do |filename, (range_start, range_end)|
                  location = path + '/' + filename

                  File.open(location, 'wb') do |file|
                    ((range_start)..(range_end)).each do |index|
                      piece = @piece[index]
                      if piece.nil?
                        file.write((["\x00"] * torrent.properties.piece_size(piece_id: index)).join(''))
                      else
                        file.write(piece)
                      end
                    end
                  end
                end
                data.clear
              end
            end
          end
        ensure
          ::KTorrent.log("Data Manager has stopped")
        end
      end

      @write_to_disk_thread = Thread.new do
        loop do
          @buffer.push(['save to disk'])
          sleep(TIME_BETWEEN_WRITES)
        end
      end
    end

    def service_stop
      return true if @service_thread.nil?
      ::KTorrent.log("Trying to stop Data Manager gracefully... please wait")
      @buffer.push(['exit']) # graceful
      sleep(EXIT_TIMEOUT)
      unless @service_thread.status == false
        ::KTorrent.log("Data Manager was forcefully stopped")
        @service_thread.kill
      end
      @service_thread = nil
      @write_to_disk_thread.kill if @write_to_disk_thread
      @write_to_disk_thread = nil
      true
    end

    def piece_to_file(index)
      info_hash + ".part#{index / pieces_per_chunk}"
    end

    def file_pieces(filename) # ranges are inclusive
      num = filename.split('.part')[1].to_i
      if num == chunks - 1
        [num * pieces_per_chunk, pieces - 1]
      else
        [num * pieces_per_chunk, (num + 1) * pieces_per_chunk - 1]
      end
    end

    def file_size(filename) # in bytes
      num = filename.split('.part')[1].to_i
      if num == chunks - 1
        total_size - (chunks - 1) * CHUNK_SIZE
      else
        CHUNK_SIZE
      end
    end

    def have?(index)
      @have[index]
    end

    def have_all
      @have.dup
    end

    def have_count
      @have_count ||= have_all.select {|have_piece| have_piece}.count
    end

    def [](index)
      have?(index) and @piece[index] or nil
    end

    def []=(index, value)
      raise ArgumentError, "value given not #{@piece_size} bytes" if value.size != torrent.properties.piece_size(piece_id: index)
      @buffer << ['write', [index, value]]
      value
    end
  end
end
