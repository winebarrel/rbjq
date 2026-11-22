# frozen_string_literal: true

require 'rbjq'

module Rbjq
  # jq-compatible command line interface.
  class CLI
    USAGE = <<~TXT
      Usage:\trbjq [OPTIONS] FILTER [FILES...]
      \trbjq [OPTIONS] --args FILTER [ARGUMENTS...]
      \trbjq [OPTIONS] --jsonargs FILTER [JSON_VALUES...]

      rbjq is a pure Ruby implementation of jq, a tool for processing JSON inputs.

      Example:

      \t$ echo '{"foo": 0}' | rbjq .
      \t{
      \t  "foo": 0
      \t}

      Command options:
        -n, --null-input          use `null` as the single input value;
        -R, --raw-input           read each line as string instead of JSON;
        -s, --slurp               read all inputs into an array and use it as
                                  the single input value;
        -c, --compact-output      compact instead of pretty-printed output;
        -r, --raw-output          output strings without escapes and quotes;
            --raw-output0         implies -r and output NUL after each output;
        -j, --join-output         implies -r and output without newline after
                                  each output;
        -a, --ascii-output        output strings by only ASCII characters
                                  using escape sequences;
        -S, --sort-keys           sort keys of each object on output;
        -C, --color-output        colorize JSON output;
        -M, --monochrome-output   disable colored output;
            --tab                 use tabs for indentation;
            --indent n            use n spaces for indentation (max 7 spaces);
            --unbuffered          flush output stream after each output;
            --stream              parse the input value in streaming fashion;
            --seq                 parse input/output as application/json-seq;
        -f, --from-file file      load filter from the file;
            --arg name value      set $name to the string value;
            --argjson name value  set $name to the JSON value;
            --slurpfile name file set $name to an array of JSON values read
                                  from the file;
            --rawfile name file   set $name to string contents of file;
            --args                consume remaining arguments as positional
                                  string values;
            --jsonargs            consume remaining arguments as positional
                                  JSON values;
        -e, --exit-status         set exit status code based on the output;
        -V, --version             show the version;
        -h, --help                show the help;
        --                        terminates argument processing;
    TXT

    def self.start(argv = ARGV, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      new(argv, stdin: stdin, stdout: stdout, stderr: stderr).run
    end

    def initialize(argv, stdin:, stdout:, stderr:)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
    end

    def run
      parse_options
      return 0 if @done

      prog = compile
      return 3 unless prog

      process(prog)
    rescue UsageError => e
      @stderr.puts "rbjq: error: #{e.message}"
      @stderr.puts 'Use rbjq --help for help with command-line options,'
      @stderr.puts 'or see the jq manpage, or online docs  at https://jqlang.github.io/jq'
      2
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
      @stderr.puts "rbjq: error: Could not open #{e.message}"
      2
    rescue Errno::EPIPE
      0
    rescue Interrupt
      130
    end

    class UsageError < StandardError; end

    private

    def parse_options
      @opts = {
        null_input: false, raw_input: false, slurp: false, compact: false, raw: false, raw0: false,
        join: false, ascii: false, sort_keys: false, color: nil, tab: false, indent: 2,
        exit_status: false, seq: false, stream: false, unbuffered: false
      }
      @named = {}
      @positional = []
      @filter = nil
      @files = []
      @from_file = nil
      @rest_kind = nil
      args = @argv
      until args.empty?
        a = args.shift
        if a == '--'
          rest = args.dup
          args.clear
          rest.each { |r| positional_arg(r) }
          next
        end

        if a.start_with?('--')
          case a
          when '--null-input' then @opts[:null_input] = true
          when '--raw-input' then @opts[:raw_input] = true
          when '--slurp' then @opts[:slurp] = true
          when '--compact-output' then @opts[:compact] = true
          when '--raw-output' then @opts[:raw] = true
          when '--raw-output0' then @opts[:raw] = @opts[:raw0] = true
          when '--join-output' then @opts[:raw] = @opts[:join] = true
          when '--ascii-output' then @opts[:ascii] = true
          when '--sort-keys' then @opts[:sort_keys] = true
          when '--color-output' then @opts[:color] = true
          when '--monochrome-output' then @opts[:color] = false
          when '--tab' then @opts[:tab] = true
          when '--indent'
            n = args.shift or raise UsageError, '--indent takes one parameter'
            raise UsageError, '--indent takes a number' unless n.match?(/\A\d+\z/)

            n = n.to_i
            raise UsageError, 'Cannot indent more than 7 characters' if n > 7

            @opts[:indent] = n
          when '--unbuffered' then @opts[:unbuffered] = true
          when '--stream' then @opts[:stream] = true
          when '--seq' then @opts[:seq] = true
          when '--exit-status' then @opts[:exit_status] = true
          when '--from-file' then @from_file = args.shift or raise UsageError, '-f takes a parameter'
          when '--arg'
            name, value = take2(args, '--arg')
            @named[name] = value
          when '--argjson'
            name, text = take2(args, '--argjson')
            begin
              @named[name] = JSONParser.parse(text)
            rescue ParseError
              raise UsageError, "Invalid JSON text passed to --argjson"
            end
          when '--slurpfile', '--rawfile'
            name, file = take2(args, a)
            data = File.read(file)
            @named[name] = a == '--rawfile' ? data : JSONParser.parse_all(data)
          when '--args' then @rest_kind = :string
          when '--jsonargs' then @rest_kind = :json
          when '--help'
            @stdout.puts USAGE
            @done = true
            return
          when '--version'
            @stdout.puts "rbjq-#{VERSION}"
            @done = true
            return
          when '--debug-dump-disasm', '--debug-trace' then nil
          else
            raise UsageError, "Unknown option: #{a}"
          end
        elsif a.start_with?('-') && a.length > 1
          shorts = a[1..].chars
          shorts.each do |c|
            case c
            when 'n' then @opts[:null_input] = true
            when 'R' then @opts[:raw_input] = true
            when 's' then @opts[:slurp] = true
            when 'c' then @opts[:compact] = true
            when 'r' then @opts[:raw] = true
            when 'j' then @opts[:raw] = @opts[:join] = true
            when 'a' then @opts[:ascii] = true
            when 'S' then @opts[:sort_keys] = true
            when 'C' then @opts[:color] = true
            when 'M' then @opts[:color] = false
            when 'e' then @opts[:exit_status] = true
            when 'f' then @from_file = args.shift or raise UsageError, '-f takes a parameter'
            when 'L' then args.shift
            when 'h'
              @stdout.puts USAGE
              @done = true
              return
            when 'V'
              @stdout.puts "rbjq-#{VERSION}"
              @done = true
              return
            else
              raise UsageError, "Unknown option: #{a}"
            end
          end
        else
          positional_arg(a)
        end
      end
    end

    def take2(args, opt)
      raise UsageError, "#{opt} takes two parameters (e.g. #{opt} varname value)" if args.size < 2

      [args.shift, args.shift]
    end

    def positional_arg(a)
      if @filter.nil? && @from_file.nil?
        @filter = a
      elsif @rest_kind
        add_positional(a, @rest_kind)
      else
        @files << a
      end
    end

    def add_positional(a, kind)
      if kind == :json
        begin
          @positional << JSONParser.parse(a)
        rescue ParseError
          raise UsageError, "Invalid JSON text passed to --jsonargs"
        end
      else
        @positional << a
      end
    end

    def compile
      if @from_file
        src = File.read(@from_file)
        # with -f, the first positional (if any) is an input file
        @files.unshift(@filter) if @filter
        @filter = src
      end
      if @filter.nil?
        @stderr.puts USAGE
        @done = true
        return nil
      end

      vars = @named.dup
      vars['ARGS'] = { 'positional' => @positional, 'named' => @named.dup }
      vars['__prog_args'] = @positional
      @current_file = nil
      Program.new(@filter, vars: vars, stderr: @stderr, filename_proc: -> { @current_file })
    rescue CompileError => e
      @stderr.puts "rbjq: error: #{e.message}"
      @stderr.puts 'rbjq: 1 compile error'
      nil
    end

    # ------------------------------------------------------------ inputs

    def sources
      if @files.empty?
        [[nil, @stdin]]
      else
        @files.map { |f| [f, nil] }
      end
    end

    def read_source(name, io)
      if io
        io.binmode if io.respond_to?(:binmode)
        io.read
      else
        File.binread(name)
      end
    end

    # Returns an Enumerator of input values
    def input_values
      Enumerator.new do |y|
        if @opts[:raw_input]
          if @opts[:slurp]
            all = +''
            sources.each do |name, io|
              @current_file = name
              all << read_source(name, io)
            end
            y << all.force_encoding(Encoding::UTF_8).scrub("�")
          else
            carry = +''
            sources.each do |name, io|
              @current_file = name
              data = carry + read_source(name, io).force_encoding(Encoding::UTF_8)
              lines = data.split("\n", -1)
              carry = lines.pop || +''
              lines.each { |l| y << l.scrub("�") }
            end
            y << carry.scrub("�") unless carry.empty?
          end
        elsif @opts[:slurp]
          all = []
          sources.each do |name, io|
            @current_file = name
            each_json(read_source(name, io)) { |v| all << v }
          end
          y << all
        else
          sources.each do |name, io|
            @current_file = name
            each_json(read_source(name, io)) { |v| y << v }
          end
        end
      end
    end

    def each_json(text, &blk)
      text = text.delete("\x1e") if @opts[:seq]
      parser = JSONParser.new(text)
      loop do
        v = parser.next_value
        break if v.equal?(JSONParser::EOF)

        if @opts[:stream]
          stream_events(v, [], true, &blk)
        else
          yield v
        end
      end
    end

    def stream_events(v, path, top, &blk)
      case v
      when Array
        if v.empty?
          yield [path, []]
        else
          v.each_with_index { |e, i| stream_events(e, path + [i], false, &blk) }
          yield [path + [v.length - 1]]
        end
      when Hash
        if v.empty?
          yield [path, {}]
        else
          v.each { |k, e| stream_events(e, path + [k], false, &blk) }
          yield [path + [v.keys.last]]
        end
      else
        yield [path, v]
      end
      nil
    end

    # ------------------------------------------------------------ output

    def color?
      return @opts[:color] unless @opts[:color].nil?
      return false if ENV['NO_COLOR'] && !ENV['NO_COLOR'].empty?

      @stdout.respond_to?(:tty?) && @stdout.tty?
    end

    def encoder
      indent = @opts[:compact] ? 0 : @opts[:indent]
      tab = !@opts[:compact] && @opts[:tab]
      Encoder.new(indent: indent, tab: tab, sort_keys: @opts[:sort_keys], ascii: @opts[:ascii],
                  color: color?, colors: Encoder.parse_colors(ENV['JQ_COLORS']))
    end

    def process(prog)
      enc = encoder
      values = input_values
      provider = lambda do
        values.next
      rescue StopIteration
        JSONParser::EOF
      end

      status = 0
      last_output = :none
      error_status = nil
      emit = lambda do |v|
        @stdout.write("\x1e") if @opts[:seq]
        if @opts[:raw] && v.is_a?(String)
          s = v
          s = Encoder.escape_string(v, true)[1...-1] if @opts[:ascii]
          @stdout.write(s)
        else
          @stdout.write(enc.encode(v))
        end
        if @opts[:raw0]
          @stdout.write("\0")
        elsif !@opts[:join]
          @stdout.write("\n")
        end
        @stdout.flush if @opts[:unbuffered]
        last_output = v
      end

      run_one = lambda do |input|
        prog.each(input, inputs: provider) { |v| emit.call(v) }
      rescue JQError => e
        print_error(e)
        error_status = 5
      end

      if @opts[:null_input]
        run_one.call(nil)
      else
        loop do
          v = provider.call
          break if v.equal?(JSONParser::EOF)

          run_one.call(v)
        end
      end

      status = error_status if error_status
      if @opts[:exit_status] && status.zero?
        status = if last_output == :none
                   4
                 elsif last_output.nil? || last_output == false
                   1
                 else
                   0
                 end
      end
      status
    rescue ParseError => e
      @stderr.puts "rbjq: error (at #{location}): #{e.message}"
      2
    rescue HaltError => e
      if e.value?
        if e.value.is_a?(String)
          @stderr.write(e.value)
        else
          @stderr.puts(Encoder.dump(e.value))
        end
      end
      e.code
    end

    def location
      "#{@current_file || '<stdin>'}:0"
    end

    def print_error(e)
      v = e.value
      if v.is_a?(String)
        @stderr.puts "rbjq: error (at #{location}): #{v}"
      else
        @stderr.puts "rbjq: error (at #{location}) (not a string): #{Encoder.dump(v)}"
      end
    end
  end
end
