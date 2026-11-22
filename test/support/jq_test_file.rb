# frozen_string_literal: true

# Parser for jq's own test-suite format (tests/*.test in the jq repository).
#
#   # comment
#   PROGRAM
#   INPUT
#   EXPECTED OUTPUT 1
#   EXPECTED OUTPUT 2
#   (blank line)
#
#   %%FAIL            (or %%FAIL IGNORE MSG)
#   PROGRAM
#   EXPECTED ERROR MESSAGE
#   (blank line)
module JqTestFile
  Case = Struct.new(:file, :line, :program, :input, :outputs, :fail, keyword_init: true)

  module_function

  def parse(path)
    lines = File.readlines(path, chomp: true, encoding: 'UTF-8')
    cases = []
    i = 0
    while i < lines.size
      line = lines[i]
      if line.strip.empty? || line.start_with?('#')
        i += 1
        next
      end

      start = i + 1
      if line.start_with?('%%FAIL')
        program = lines[i + 1]
        i += 2
        msg = []
        while i < lines.size && !lines[i].strip.empty?
          msg << lines[i]
          i += 1
        end
        cases << Case.new(file: File.basename(path), line: start, program: program, fail: msg.join("\n"))
      else
        program = line
        input = lines[i + 1]
        i += 2
        outputs = []
        while i < lines.size && !lines[i].strip.empty?
          outputs << lines[i] unless lines[i].start_with?('#')
          i += 1
        end
        cases << Case.new(file: File.basename(path), line: start, program: program, input: input, outputs: outputs)
      end
    end
    cases
  end
end
