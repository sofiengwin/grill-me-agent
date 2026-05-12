require "digest"
require "fileutils"
require "json"
require "time"

module GrillMe
  # Filesystem-backed cache for tool results and LLM responses.
  #
  # Keys are SHA-256 hashes of the canonical JSON of (tool_name, args).
  # Entries live under <base_dir>/<subdir>/<key>.json and carry a written_at
  # timestamp plus a per-tool TTL. LLM entries use ttl_s: nil (infinite).
  class Cache
    TOOLS_SUBDIR = "tools".freeze
    LLM_SUBDIR = "llm".freeze

    THIRTY_DAYS = 30 * 24 * 60 * 60
    SEVEN_DAYS = 7 * 24 * 60 * 60

    TTLS = {
      "wikipedia_page" => THIRTY_DAYS,
      "wikipedia_search" => THIRTY_DAYS,
      "wikidata_sparql" => THIRTY_DAYS,
      "web_search" => SEVEN_DAYS,
      "web_fetch" => SEVEN_DAYS,
      "llm" => nil
    }.freeze

    attr_reader :base_dir, :no_cache, :refresh

    def initialize(base_dir: ".cache", no_cache: false, refresh: false)
      @base_dir = base_dir
      @no_cache = no_cache
      @refresh = refresh
    end

    # Wraps a computation with cache lookup/store semantics.
    # When no_cache is true, the block runs every time and nothing is persisted.
    # When refresh is true, reads are skipped but the result is still written.
    def fetch(tool_name, args_hash)
      raise ArgumentError, "block required" unless block_given?

      if @no_cache
        return yield
      end

      subdir = subdir_for(tool_name)
      key = key_for(tool_name, args_hash)

      unless @refresh
        cached = read(key, subdir)
        return cached unless cached.nil?
      end

      result = yield
      write(key, result, subdir, ttl: ttl_for(tool_name))
      result
    end

    # Returns the parsed `data` payload for a cache hit, or nil for miss/expired.
    def read(key, subdir)
      path = path_for(key, subdir)
      return nil unless File.exist?(path)
      return nil if expired?(path)

      payload = JSON.parse(File.read(path))
      payload["data"]
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    # Persists value with metadata. Creates the subdirectory on demand.
    def write(key, value, subdir, ttl:)
      dir = File.join(@base_dir, subdir)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{key}.json")
      payload = {
        "data" => value,
        "written_at" => Time.now.utc.iso8601,
        "ttl_s" => ttl
      }
      File.write(path, JSON.generate(payload))
      value
    rescue SystemCallError => e
      raise CacheError, "failed to write cache entry #{path}: #{e.message}"
    end

    # Recursively wipes the tools/ and llm/ subdirectories.
    def clear!
      [TOOLS_SUBDIR, LLM_SUBDIR].each do |sub|
        path = File.join(@base_dir, sub)
        FileUtils.rm_rf(path)
      end
    end

    private

    def subdir_for(tool_name)
      tool_name.to_s == "llm" ? LLM_SUBDIR : TOOLS_SUBDIR
    end

    def key_for(tool_name, args_hash)
      sha256(canonical_json("tool" => tool_name.to_s, "args" => args_hash))
    end

    def path_for(key, subdir)
      File.join(@base_dir, subdir, "#{key}.json")
    end

    def expired?(file_path)
      payload = JSON.parse(File.read(file_path))
      ttl = payload["ttl_s"]
      return false if ttl.nil?

      written_at = Time.iso8601(payload["written_at"])
      (written_at + ttl) < Time.now
    rescue Errno::ENOENT, JSON::ParserError, ArgumentError
      true
    end

    def ttl_for(tool_name)
      TTLS.fetch(tool_name.to_s, SEVEN_DAYS)
    end

    def canonical_json(obj)
      JSON.generate(deep_sort(obj))
    end

    def deep_sort(obj)
      case obj
      when Hash
        obj.keys.map(&:to_s).sort.each_with_object({}) do |k, acc|
          original_key = obj.key?(k) ? k : k.to_sym
          acc[k] = deep_sort(obj[original_key])
        end
      when Array
        obj.map { |v| deep_sort(v) }
      else
        obj
      end
    end

    def sha256(str)
      Digest::SHA256.hexdigest(str)
    end
  end
end
