module KTorrent
  class BEncoding
    BadBEncoding = Class.new(StandardError)

    def initialize(data)
      @data = data
      @index = 0
    end

    def decode
      parse_data_stream
    end

    def self.decode(data)
      self.new(data).decode
    end

    def self.encode(object)
      case object
      when Hash
        "d#{object.sort.flatten(1).map{ |o| self.encode(o) }.join('')}e"
      when Array
        "l#{object.map{ |o| self.encode(o) }.join('')}e"
      when Numeric
        "i#{object.to_i}e"
      when String
        "#{object.size}:#{object}"
      else
        raise ArgumentError, "Improper BEncoded object"
      end
    end

    private

    def parse_data_stream
      byte = @data[@index]
      case byte
      when nil
        nil
      when 'd'
        @index += 1
        items = []
        until @data[@index] == 'e' || @data[@index].nil?
          items << parse_data_stream
        end
        @index += 1
        Hash[items.each_slice(2).to_a]
      when 'l'
        @index += 1
        items = []
        until @data[@index] == 'e' || @data[@index].nil?
          items << parse_data_stream
        end
        @index += 1
        items
      when 'i'
        string_end_idx = @data.index('e', @index)
        @index += 1
        raise "Failed to parse integer: no end" if string_end_idx.nil?
        number = @data.slice(@index, string_end_idx - @index).to_i
        @index = string_end_idx + 1
        number
      else
        colon_idx = @data.index(':', @index)
        raise "Failed to parse string: no colon" if colon_idx.nil?
        string_size = @data.slice(@index, colon_idx - @index).to_i
        str = @data.slice(colon_idx + 1, string_size)
        @index = colon_idx + 1 + string_size
        str
      end
    end
  end
end
