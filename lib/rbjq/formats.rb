# frozen_string_literal: true

module Rbjq
  # @text, @json, @csv, @tsv, @html, @uri, @urid, @sh, @base64, @base64d
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
      when 'urid' then urid(Ops.tostring(v))
      else raise JQError, "#{name} is not a valid format"
      end
    end

    HTML = { '<' => '&lt;', '>' => '&gt;', '&' => '&amp;', "'" => '&apos;', '"' => '&quot;' }.freeze

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
        else raise JQError, "#{Value.desc(e)} is not valid in a csv row"
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
      # like jq: decoding stops at the first '=', other characters are errors
      str = s.split('=', 2).first || ''
      raise JQError, "#{Value.desc(s)} is not valid base64 data" if str.match?(%r{[^A-Za-z0-9+/]})
      raise JQError, "#{Value.desc(s)} trailing base64 byte found" if str.length % 4 == 1

      str += '=' * ((4 - (str.length % 4)) % 4)
      out = str.unpack1('m')
      Value.scrub_utf8(out)
    end

    def urid(s)
      bad = -> { raise JQError, "#{Value.desc(s)} is not a valid uri encoding" }
      out = s.b.gsub(/%(..)?/n) do
        hex = Regexp.last_match(1)
        bad.call unless hex&.match?(/\A[0-9A-Fa-f]{2}\z/)
        hex.to_i(16).chr
      end
      out.force_encoding(Encoding::UTF_8)
      bad.call unless out.valid_encoding?
      out
    end
  end
end
