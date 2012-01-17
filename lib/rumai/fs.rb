# File system abstractions over the 9P2000 protocol.

require 'rumai/ixp'
require 'socket'

module Rumai
  # address of the IXP server socket on this machine
  def self.ixp_sock_addr
    display = ENV['DISPLAY'] || ':0.0'

    ENV['WMII_ADDRESS'].sub(/.*!/, '') rescue
      "/tmp/ns.#{ENV['USER']}.#{display[/:\d+/]}/wmii"
  end

  def self.ixp_agent
    # we use a single, global connection to wmii's IXP server
    @agent ||= IXP::Agent.new(UNIXSocket.new(ixp_sock_addr))
  rescue => error
    error.message << %{\n
Ensure that (1) the WMII_ADDRESS environment variable is set and that (2) it
correctly specifies the absolute filesystem path to wmii's IXP socket file,
which is typically located at "/tmp/ns.${USER}.${DISPLAY}/wmii".
\n}
    raise error
  end

  ##
  # An entry in the IXP file system.
  #
  class Node
    attr_reader :path

    def initialize path
      @path = path.to_s.squeeze('/')
    end

    ##
    # Returns file statistics about this node.
    #
    # @see Rumai::IXP::Agent#stat
    #
    def stat
      Rumai.ixp_agent.stat @path
    end

    ##
    # Tests if this node exists on the IXP server.
    #
    def exist?
      begin
        true if stat
      rescue IXP::Error
        false
      end
    end

    ##
    # Tests if this node is a directory.
    #
    # @see Rumai::IXP::Agent#stat
    #
    def directory?
      exist? and stat.directory?
    end

    ##
    # Returns the names of all files in this directory.
    #
    # @see Rumai::IXP::Agent#entries
    #
    def entries
      catching_ixp_errors 'get entries', [] do
        Rumai.ixp_agent.entries @path
      end
    end

    ##
    # Opens this node for I/O access.
    #
    # @see Rumai::IXP::Agent#open
    #
    def open mode = 'r', &block
      Rumai.ixp_agent.open @path, mode, &block
    end

    ##
    # Returns the entire content of this node.
    #
    # @see Rumai::IXP::Agent#read
    #
    def read *args
      catching_ixp_errors 'read from' do
        Rumai.ixp_agent.read @path, *args
      end
    end

    ##
    # Invokes the given block for every line in the content of this node.
    #
    # @yieldparam [String] line
    #
    def each_line &block
      raise ArgumentError unless block_given?
      open do |file|
        until (chunk = file.read(true)).empty?
          chunk.each_line(&block)
        end
      end
    end

    ##
    # Writes the given content to this node.
    #
    # @see Rumai::IXP::Agent#write
    #
    def write content
      catching_ixp_errors 'write to' do
        Rumai.ixp_agent.write @path, content
      end
    end

    ##
    # Creates a file corresponding to this node on the IXP server.
    #
    # @see Rumai::IXP::Agent#create
    #
    def create *args
      catching_ixp_errors 'create on' do
        Rumai.ixp_agent.create @path, *args
      end
    end

    ##
    # Deletes the file corresponding to this node on the IXP server.
    #
    # @see Rumai::IXP::Agent#remove
    #
    def remove
      catching_ixp_errors 'remove from' do
        Rumai.ixp_agent.remove @path
      end
    end

    @@cache = Hash.new {|h,k| h[k] = Node.new(k) }

    ##
    # Returns the given sub-path as a Node object.
    #
    def [] sub_path
      @@cache[ File.join(@path, sub_path.to_s) ]
    end

    ##
    # Returns the parent node of this node.
    #
    def parent
      @@cache[ File.dirname(@path) ]
    end

    ##
    # Returns all child nodes of this node.
    #
    def children
      entries.map! {|c| self[c] }
    end

    include Enumerable

      ##
      # Iterates through each child of this directory.
      #
      def each &block
        children.each(&block)
      end

    ##
    # Deletes all child nodes.
    #
    def clear
      children.each do |c|
        c.remove
      end
    end

    def catching_ixp_errors(action="do", fallback=nil)
      yield
    rescue IXP::Error => e
      STDERR.puts "could not #{action} IXP Agent (#{Rumai.ixp_sock_addr}): #{e}\n#{e.backtrace.join("\n")}\n  => trying to continue anyway"
      return fallback
    end

    ##
    # Provides access to child nodes through method calls.
    #
    # :call-seq: node.child -> Node
    #
    def method_missing meth, *args
      child = self[meth]

      # speed up future accesses
      (class << self; self; end).instance_eval do
        define_method meth do
          child
        end
      end

      child
    end
  end

  ##
  # Makes instance methods accessible through class
  # methods. This is done to emulate the File class:
  #
  #   File.exist? "foo"
  #   File.new("foo").exist?
  #
  # Both of the above expressions are equivalent.
  #
  module ExportInstanceMethods
    def self.extended target # @private
      target.instance_methods(false).each do |meth|
        (class << target; self; end).instance_eval do
          define_method meth do |path, *args|
            new(path).__send__(meth, *args)
          end
        end
      end
    end
  end

  ##
  # NOTE: We use extend() **AFTER** all methods have been defined
  #       in the class so that the ExportInstanceMethods module
  #       can do its magic.  If, instead, we include()d the module
  #       before all methods in the class had been defined, then
  #       the magic would only apply to **SOME** of the methods!
  #
  Node.extend ExportInstanceMethods
end
