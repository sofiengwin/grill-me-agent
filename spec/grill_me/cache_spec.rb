require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe GrillMe::Cache do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:cache) { described_class.new(base_dir: tmp_dir) }

  after { FileUtils.rm_rf(tmp_dir) }

  describe "#read / #write" do
    it "reads a cached value" do
      cache.write("k1", { "foo" => "bar" }, "tools", ttl: 60)
      expect(cache.read("k1", "tools")).to eq({ "foo" => "bar" })
    end

    it "returns nil on cache miss" do
      expect(cache.read("missing", "tools")).to be_nil
    end

    it "expires entries after TTL" do
      cache.write("k_ttl", "v", "tools", ttl: 1)
      sleep 1.1
      expect(cache.read("k_ttl", "tools")).to be_nil
    end

    it "does not expire entries with nil TTL" do
      cache.write("k_forever", "v", "llm", ttl: nil)
      sleep 0.1
      expect(cache.read("k_forever", "llm")).to eq("v")
    end

    it "stores and retrieves nested hashes" do
      payload = { "a" => { "b" => [1, 2, { "c" => "d" }] }, "e" => nil }
      cache.write("nested", payload, "tools", ttl: 60)
      expect(cache.read("nested", "tools")).to eq(payload)
    end
  end

  describe "#fetch" do
    it "yields and writes on miss, then reads on next call" do
      calls = 0
      first = cache.fetch("wikipedia_page", { "title" => "X" }) { calls += 1; "result" }
      second = cache.fetch("wikipedia_page", { "title" => "X" }) { calls += 1; "should_not_run" }
      expect(first).to eq("result")
      expect(second).to eq("result")
      expect(calls).to eq(1)
    end

    it "bypasses read when no_cache is true" do
      no_cache = described_class.new(base_dir: tmp_dir, no_cache: true)
      calls = 0
      3.times { no_cache.fetch("wikipedia_page", { "title" => "X" }) { calls += 1; "r" } }
      expect(calls).to eq(3)
    end

    it "bypasses read but still writes when refresh is true" do
      refresher = described_class.new(base_dir: tmp_dir, refresh: true)
      reader = described_class.new(base_dir: tmp_dir)
      calls = 0

      refresher.fetch("wikipedia_page", { "title" => "X" }) { calls += 1; "first" }
      expect(calls).to eq(1)

      refresher.fetch("wikipedia_page", { "title" => "X" }) { calls += 1; "second" }
      expect(calls).to eq(2)

      result = reader.fetch("wikipedia_page", { "title" => "X" }) { calls += 1; "should_not_run" }
      expect(result).to eq("second")
      expect(calls).to eq(2)
    end

    it "raises ArgumentError when no block given" do
      expect { cache.fetch("wikipedia_page", {}) }.to raise_error(ArgumentError)
    end
  end

  describe "key canonicalization" do
    it "canonicalizes keys consistently regardless of hash key order" do
      key1 = cache.send(:key_for, "wikipedia_page", { "a" => 1, "b" => 2 })
      key2 = cache.send(:key_for, "wikipedia_page", { "b" => 2, "a" => 1 })
      expect(key1).to eq(key2)
    end

    it "treats symbol and string keys equivalently" do
      key1 = cache.send(:key_for, "wikipedia_page", { a: 1, b: 2 })
      key2 = cache.send(:key_for, "wikipedia_page", { "a" => 1, "b" => 2 })
      expect(key1).to eq(key2)
    end

    it "produces different keys for different args" do
      key1 = cache.send(:key_for, "wikipedia_page", { "a" => 1 })
      key2 = cache.send(:key_for, "wikipedia_page", { "a" => 2 })
      expect(key1).not_to eq(key2)
    end
  end

  describe "subdir routing" do
    it "uses tools/ subdir for non-llm tools" do
      cache.fetch("wikipedia_page", { "title" => "X" }) { "r" }
      expect(Dir.exist?(File.join(tmp_dir, "tools"))).to be true
    end

    it "uses llm/ subdir for llm calls" do
      cache.fetch("llm", { "messages" => [] }) { "r" }
      expect(Dir.exist?(File.join(tmp_dir, "llm"))).to be true
    end
  end

  describe "TTL per tool type" do
    it "uses 30 days for wikipedia_page" do
      expect(cache.send(:ttl_for, "wikipedia_page")).to eq(30 * 24 * 60 * 60)
    end

    it "uses 30 days for wikipedia_search and wikidata_sparql" do
      expect(cache.send(:ttl_for, "wikipedia_search")).to eq(30 * 24 * 60 * 60)
      expect(cache.send(:ttl_for, "wikidata_sparql")).to eq(30 * 24 * 60 * 60)
    end

    it "uses 7 days for web_search and web_fetch" do
      expect(cache.send(:ttl_for, "web_search")).to eq(7 * 24 * 60 * 60)
      expect(cache.send(:ttl_for, "web_fetch")).to eq(7 * 24 * 60 * 60)
    end

    it "uses nil (infinite) for llm" do
      expect(cache.send(:ttl_for, "llm")).to be_nil
    end
  end

  describe "#clear!" do
    it "removes all cached entries under tools/ and llm/" do
      cache.fetch("wikipedia_page", { "title" => "X" }) { "r" }
      cache.fetch("llm", { "messages" => [] }) { "r" }
      expect(Dir.exist?(File.join(tmp_dir, "tools"))).to be true
      expect(Dir.exist?(File.join(tmp_dir, "llm"))).to be true

      cache.clear!

      expect(Dir.exist?(File.join(tmp_dir, "tools"))).to be false
      expect(Dir.exist?(File.join(tmp_dir, "llm"))).to be false
    end
  end

  describe "filesystem error handling" do
    it "raises CacheError when File.write fails" do
      allow(File).to receive(:write).and_raise(Errno::EACCES.new("permission denied"))
      expect {
        cache.write("k", "v", "tools", ttl: 60)
      }.to raise_error(GrillMe::CacheError, /failed to write cache entry/)
    end
  end
end
