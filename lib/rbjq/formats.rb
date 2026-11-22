# frozen_string_literal: true


module Rbjq
  # @text, @json, @csv, @tsv, @html, @uri, @sh, @base64, @base64d, @base32, @base32d
  module Formats
    module_function

    def apply(name, v)
      case name
      when 'text' then Ops.tostring(v)
      when 'json' then Encoder.dump(v)
      when 'html' then html(Ops.tostring(v))
      when 'uri' then uri(Ops.tostring(v))
      when 'csv' then csv(v)
      when 'tsv' then tsv(v)
      when 'sh' then sh(v)
      when 'base64' then [Ops.tostring(v)].pack('m0').force_encoding(Encoding::UTF_8)
      when 'base64d' then base64d(Ops.tostring(v))
      when 'base32' then base32(Ops.tostring(v))
      when 'base32d' then base32d(Ops.tostring(v))
      else raise JQError, "#{name} is not a valid format"
      end
    end

    HTML = { '<' => '&lt;', '>' => '&gt;', '&' => '&amp;', "'" => '&#39;', '"' => '&quot;' }.freeze

    def html(s)
      s.gsub(/[<>&'"]/, HTML)
    end

    def uri(s)
      s.b.gsub(/[^A-Za-z0-9\-_.~]/n) { |c| format('%%%02X', c.ord) }.force_encoding(Encoding::UTF_8)
    end

    def csv(v)
      raise JQError, "#{Value.desc(v)} cannot be csv-formatted, only array" unless v.is_a?(Array)

      v.map do |e|
        case e
        when Integer, Float then Encoder.format_number(e)
        when String then "\"#{e.gsub('"', '""')}\""
        when true then 'true'
        when false then 'false'
        when nil then ''
        else raise JQError, "#{Value.desc(e)} is not valid in a csv row"
        end
      end.join(',')
    end

    def tsv(v)
      raise JQError, "#{Value.desc(v)} cannot be tsv-formatted, only array" unless v.is_a?(Array)

      v.map do |e|
        case e
        when Integer, Float then Encoder.format_number(e)
        when String then e.gsub(/[\\\t\n\r]/, '\\' => '\\\\', "\t" => '\\t', "\n" => '\\n', "\r" => '\\r')
        when true then 'true'
        when false then 'false'
        when nil then ''
        else raise JQError, "#{Value.desc(e)} is not valid in a tsv row"
        end
      end.join("\t")
    end

    def sh(v)
      items = v.is_a?(Array) ? v : [v]
      items.map do |e|
        case e
        when String then "'#{e.gsub("'", "'\\\\''")}'"
        when Array, Hash then raise JQError, "#{Value.desc(e)} can not be escaped for shell"
        else Encoder.dump(e)
        end
      end.join(' ')
    end

    def base64d(s)
      str = s.delete("=")
      str = str.gsub(/[^A-Za-z0-9+\/]/, '')
      if str.length % 4 == 1
        raise JQError, "#{Value.desc(s)} trailing base64 byte found"
      end

      str += '=' * ((4 - str.length % 4) % 4)
      out = str.unpack1('m')
      out.force_encoding(Encoding::UTF_8).scrub("�")
    end

    B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'

    def base32(s)
      bits = s.b.unpack1('B*')
      out = bits.scan(/.{1,5}/).map { |chunk| B32[chunk.ljust(5, '0').to_i(2)] }.join
      out += '=' * ((8 - out.length % 8) % 8)
      out
    end

    def base32d(s)
      str = s.delete('=').upcase
      bits = str.each_char.map do |c|
        i = B32.index(c)
        raise JQError, "#{Value.desc(s)} is not valid base32 data" unless i

        format('%05b', i)
      end.join
      bytes = bits.scan(/.{8}/).map { |b| b.to_i(2) }.pack('C*')
      bytes.force_encoding(Encoding::UTF_8).scrub("�")
    end
  end
end
