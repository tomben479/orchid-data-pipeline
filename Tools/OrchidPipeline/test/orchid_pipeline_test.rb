# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/orchid_pipeline"

class OrchidPipelineTest < Minitest::Test
  def test_parser_matches_orchid_contract
    root = JSON.parse(<<~JSON)
      {
        "getVector": {
          "items": [
            {
              "type": "playlist",
              "ref": "playlist-1",
              "title": "Taiwan Hits",
              "size": 24,
              "thumbnailHQ": "//i.ytimg.com/vi/abc/maxresdefault.jpg"
            }
          ]
        }
      }
    JSON

    collection = OrchidPipeline::PayloadParser.collections(root).first

    assert_equal("playlist-1", collection.fetch("id"))
    assert_equal("24 首", collection.fetch("subtitle"))
    assert_equal("https://i.ytimg.com/vi/abc/maxresdefault.jpg", collection.fetch("thumbnailURL"))
    assert_equal({ "width" => 1280, "height" => 720 }, collection.fetch("thumbnailSize"))
  end

  def test_vector_discovery_deduplicates_and_ignores_artist_vectors
    root = {
      "items" => [
        { "type" => "genre", "ref" => "vector_custom" },
        { "type" => "genre", "ref" => "vector_artists_zh" },
        {
          "apiInfo" => {
            "funcName" => "getVector",
            "arguments" => { "vectorId" => "vector_custom" }
          }
        }
      ]
    }

    assert_equal(["vector_custom"], OrchidPipeline::PayloadParser.vector_ids(root))
  end

  def test_parser_rejects_unsafe_artwork_and_malformed_youtube_ids
    root = {
      "getPlaylist" => {
        "items" => [
          {
            "type" => "music",
            "t" => "yt",
            "f" => "../../escape",
            "tt" => "Unsafe",
            "thumbnailHQ" => "javascript:alert(1)"
          },
          {
            "type" => "music",
            "t" => "yt",
            "f" => "valid_id-01",
            "tt" => "Safe",
            "thumbnailHQ" => "javascript:alert(1)"
          }
        ]
      }
    }

    tracks = OrchidPipeline::PayloadParser.tracks(root)

    assert_equal(1, tracks.length)
    assert_equal("valid_id-01", tracks.first.fetch("id"))
    assert_equal("https://i.ytimg.com/vi/valid_id-01/mqdefault.jpg", tracks.first.fetch("thumbnailURL"))
  end

  def test_first_build_then_conditional_build_reuses_payloads
    Dir.mktmpdir do |directory|
      transport = FakeTransport.new
      output = File.join(directory, "public")
      state = File.join(directory, "source-state.json")
      first_launches = []
      transport.handler = lambda do |request|
        first_launches << request.fetch(:query).fetch("firstLaunch")
        response_for(request, conditional: false)
      end

      first = build(transport, output, state, now: Time.utc(2026, 7, 10, 8, 16, 0))
      assert_equal(true, first.fetch("changed"))
      assert_equal(1, first.fetch("collectionCount"))
      assert_equal(1, first.fetch("trackCount"))
      assert_equal(1, first_launches.uniq.length)
      manifest_before = File.read(File.join(output, "manifest.json"))
      manifest = JSON.parse(manifest_before)
      catalog_path = File.join(output, manifest.dig("catalog", "path"))
      assert_equal(
        manifest.dig("catalog", "sha256"),
        Digest::SHA256.hexdigest(File.binread(catalog_path))
      )
      state_before = File.read(state)

      transport.handler = ->(request) { response_for(request, conditional: true) }
      second = build(transport, output, state, now: Time.utc(2026, 7, 10, 14, 16, 0))

      assert_equal(false, second.fetch("changed"))
      assert_equal(2, second.fetch("notModifiedCount"))
      assert_equal(manifest_before, File.read(File.join(output, "manifest.json")))
      assert_equal(state_before, File.read(state))
      assert(transport.requests.any? { |request| request[:etag] == '"vector-etag"' })
      assert(transport.requests.any? { |request| request[:etag] == '"playlist-etag"' })

      File.write(catalog_path, OrchidPipeline::CanonicalJSON.pretty(JSON.parse(File.read(catalog_path))))
      repaired = build(transport, output, state, now: Time.utc(2026, 7, 10, 20, 16, 0))
      repaired_manifest = JSON.parse(File.read(File.join(output, "manifest.json")))
      repaired_path = File.join(output, repaired_manifest.dig("catalog", "path"))

      assert_equal(true, repaired.fetch("changed"))
      assert_equal(
        repaired_manifest.dig("catalog", "sha256"),
        Digest::SHA256.hexdigest(File.binread(repaired_path))
      )
    end
  end

  def test_quality_gate_does_not_replace_last_known_good_manifest
    Dir.mktmpdir do |directory|
      transport = FakeTransport.new
      output = File.join(directory, "public")
      state = File.join(directory, "source-state.json")
      transport.handler = ->(request) { response_for(request, conditional: false) }
      build(transport, output, state)
      manifest_before = File.read(File.join(output, "manifest.json"))

      assert_raises(OrchidPipeline::QualityGateError) do
        OrchidPipeline::Builder.new(
          transport: transport,
          output_directory: output,
          state_path: state,
          max_vectors: 1,
          max_pages_per_vector: 1,
          minimum_collections: 2,
          first_launch: "fixed",
          now: -> { Time.utc(2026, 7, 10, 8, 16, 0) },
          logger: ->(_message) {}
        ).build
      end

      assert_equal(manifest_before, File.read(File.join(output, "manifest.json")))
    end
  end

  def test_vector_batches_rotate_and_accumulate_cached_collections
    Dir.mktmpdir do |directory|
      transport = FakeTransport.new
      output = File.join(directory, "public")
      state = File.join(directory, "source-state.json")
      requested_vectors = []
      transport.handler = lambda do |request|
        if request.fetch(:path) == "/api/page/getSearch"
          json_result({ "getPage" => { "items" => [] } }, etag: '"discovery"')
        elsif request.fetch(:path) == "/api/getVector"
          vector_id = request.fetch(:query).fetch("vectorId")
          requested_vectors << vector_id
          json_result(
            {
              "getVector" => {
                "items" => [{ "type" => "playlist", "ref" => vector_id, "title" => vector_id }]
              }
            },
            etag: "\"#{vector_id}\""
          )
        else
          raise("Unexpected path #{request.fetch(:path)}")
        end
      end

      2.times do |index|
        OrchidPipeline::Builder.new(
          transport: transport,
          output_directory: output,
          state_path: state,
          max_vectors: 2,
          max_pages_per_vector: 1,
          vector_batch_size: 1,
          playlist_batch_size: 0,
          minimum_collections: 1,
          first_launch: "fixed",
          now: -> { Time.utc(2026, 7, 10, 8, 16, 0) + (index * 6 * 60 * 60) },
          logger: ->(_message) {}
        ).build
      end

      assert_equal(2, requested_vectors.uniq.length)
      assert_equal(
        ["vector_latest_zh", "vector_systemlist_zh_top_charts"].sort,
        requested_vectors.sort
      )
      manifest = JSON.parse(File.read(File.join(output, "manifest.json")))
      catalog = JSON.parse(File.read(File.join(output, manifest.dig("catalog", "path"))))
      assert_equal(2, catalog.fetch("collections").length)
    end
  end

  def test_rate_limit_publishes_cached_feed_without_tracks_and_stops_requests
    Dir.mktmpdir do |directory|
      transport = FakeTransport.new
      output = File.join(directory, "public")
      state = File.join(directory, "source-state.json")
      transport.handler = lambda do |request|
        case request.fetch(:path)
        when "/api/page/getSearch"
          json_result({ "getPage" => { "items" => [] } }, etag: '"discovery"')
        when "/api/getVector"
          json_result(
            {
              "getVector" => {
                "items" => [{ "type" => "playlist", "ref" => "playlist-1", "title" => "Playlist" }]
              }
            },
            etag: '"vector"'
          )
        when "/api/playlist"
          raise OrchidPipeline::RateLimitError.new("rate limited", retry_after: 3600)
        end
      end

      summary = build(transport, output, state)

      assert_equal(true, summary.fetch("halted"))
      assert_match(/3600 seconds/, summary.fetch("haltReason"))
      assert_equal(0, summary.fetch("trackCount"))
      assert(File.file?(File.join(output, "manifest.json")))
    end
  end

  def test_incomplete_vector_resumes_from_checkpoint_in_next_run
    Dir.mktmpdir do |directory|
      transport = FakeTransport.new
      output = File.join(directory, "public")
      state = File.join(directory, "source-state.json")
      offsets = []
      budget_was_raised = false
      transport.handler = lambda do |request|
        if request.fetch(:path) == "/api/page/getSearch"
          json_result({ "getPage" => { "items" => [] } }, etag: '"discovery"')
        elsif request.fetch(:path) == "/api/getVector"
          offset = request.fetch(:query).fetch("skip").to_i
          offsets << offset
          if offset == 12 && !budget_was_raised
            budget_was_raised = true
            raise OrchidPipeline::RequestBudgetExceeded, "budget exhausted"
          end

          count = offset.zero? ? 12 : 1
          items = count.times.map do |index|
            { "type" => "playlist", "ref" => "playlist-#{offset + index}", "title" => "Playlist" }
          end
          json_result({ "getVector" => { "items" => items } }, etag: "\"offset-#{offset}\"")
        else
          raise("Unexpected path #{request.fetch(:path)}")
        end
      end

      2.times do
        OrchidPipeline::Builder.new(
          transport: transport,
          output_directory: output,
          state_path: state,
          max_vectors: 1,
          vector_batch_size: 1,
          playlist_batch_size: 0,
          minimum_collections: 1,
          first_launch: "fixed",
          now: -> { Time.utc(2026, 7, 10, 8, 16, 0) },
          logger: ->(_message) {}
        ).build
      end

      assert_equal([0, 12, 12], offsets)
      persisted = JSON.parse(File.read(state))
      progress = persisted.dig("vectors", "vector_systemlist_zh_top_charts")
      assert_equal(true, progress.fetch("complete"))
      assert_equal(0, progress.fetch("nextOffset"))
    end
  end

  private

  def build(transport, output, state, now: Time.utc(2026, 7, 10, 8, 16, 0))
    OrchidPipeline::Builder.new(
      transport: transport,
      output_directory: output,
      state_path: state,
      max_vectors: 1,
      max_pages_per_vector: 1,
      minimum_collections: 1,
      minimum_playlist_success_rate: 1.0,
      first_launch: "fixed-first-launch",
      now: -> { now },
      logger: ->(_message) {}
    ).build
  end

  def response_for(request, conditional:)
    case request.fetch(:path)
    when "/api/page/getSearch"
      json_result(
        {
          "getPage" => {
            "items" => [{ "type" => "genre", "ref" => "vector_systemlist_zh_top_charts" }]
          }
        },
        etag: '"discovery-etag"'
      )
    when "/api/getVector"
      return not_modified('"vector-etag"') if conditional && request[:etag] == '"vector-etag"'

      json_result(
        {
          "getVector" => {
            "items" => [
              {
                "type" => "playlist",
                "ref" => "playlist-1",
                "title" => "Taiwan Hits",
                "size" => 1
              }
            ]
          }
        },
        etag: '"vector-etag"'
      )
    when "/api/playlist"
      return not_modified('"playlist-etag"') if conditional && request[:etag] == '"playlist-etag"'

      json_result(
        {
          "getPlaylist" => {
            "items" => [
              {
                "type" => "music",
                "t" => "yt",
                "f" => "video-1",
                "tt" => "Song One",
                "tm" => 205
              }
            ]
          }
        },
        etag: '"playlist-etag"'
      )
    else
      raise("Unexpected path #{request.fetch(:path)}")
    end
  end

  def json_result(value, etag:)
    OrchidPipeline::HTTPResult.new(
      status: 200,
      headers: { "etag" => etag },
      body: JSON.generate(value)
    )
  end

  def not_modified(etag)
    OrchidPipeline::HTTPResult.new(status: 304, headers: { "etag" => etag }, body: "")
  end
end

class FakeTransport
  attr_accessor :handler
  attr_reader :requests

  def initialize
    @requests = []
  end

  def request(**request)
    @requests << request
    handler.call(request)
  end
end
