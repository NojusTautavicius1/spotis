# encoding: UTF-8

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require 'sinatra'
require 'ruby_llm'
require 'pg'
require 'json'
require 'dotenv/load'

RubyLLM.configure do |c|
  c.anthropic_api_key = ENV['ANTHROPIC_API_KEY']
  c.openai_api_key    = ENV['OPENAI_API_KEY']
end

DB = PG.connect(ENV['DATABASE_URL'])

set :port, ENV['PORT'] || 4567
set :bind, '0.0.0.0'
set :environment, :production
set :protection, except: [:host_authorization]

# ─── TOOLS ───────────────────────────────────────────────────────

class SearchByMood < RubyLLM::Tool
  description "Find songs matching a mood (e.g., 'sad', 'happy', 'energetic'). Returns up to N songs."
  param :mood,  desc: "One of: happy, sad, energetic, calm, melancholic, aggressive, romantic, uplifting"
  param :limit, type: :integer, desc: "Max number to return (default 5)", required: false

  def execute(mood:, limit: 5)
    res = DB.exec_params(
      'SELECT id, title, artist, bpm, mood, valence FROM "Song" WHERE mood = $1 ORDER BY RANDOM() LIMIT $2',
      [mood, limit]
    )
    res.map { |r| r.transform_keys(&:to_sym) }
  end
end

class SearchByBPM < RubyLLM::Tool
  description "Find songs within a BPM range. Use for 'fast', 'slow', 'good for running' queries."
  param :min_bpm, type: :integer
  param :max_bpm, type: :integer
  param :limit,   type: :integer, required: false

  def execute(min_bpm:, max_bpm:, limit: 5)
    res = DB.exec_params(
      'SELECT id, title, artist, bpm, mood FROM "Song" WHERE bpm BETWEEN $1 AND $2 ORDER BY RANDOM() LIMIT $3',
      [min_bpm, max_bpm, limit]
    )
    res.map { |r| r.transform_keys(&:to_sym) }
  end
end

class SearchByLyricalTheme < RubyLLM::Tool
  description "Find songs whose lyrics contain a given theme (e.g., 'love', 'loss', 'rebellion')."
  param :theme
  param :limit, type: :integer, required: false

  def execute(theme:, limit: 5)
    res = DB.exec_params(
      %(
        SELECT s.id, s.title, s.artist, l.mood as lyrical_mood, l.themes
        FROM "Song" s JOIN "Lyrics" l ON l."songId" = s.id
        WHERE $1 = ANY(l.themes)
        ORDER BY RANDOM() LIMIT $2
      ),
      [theme, limit]
    )
    res.map { |r| r.transform_keys(&:to_sym) }
  end
end

class FindSimilar < RubyLLM::Tool
  description "Find songs similar to a given song using embedding similarity. Use when user references a specific song."
  param :song_id
  param :limit, type: :integer, required: false

  def execute(song_id:, limit: 5)
    res = DB.exec_params(
      %(
        SELECT id, title, artist, mood
        FROM "Song"
        WHERE id != $1 AND embedding IS NOT NULL
        ORDER BY embedding <=> (SELECT embedding FROM "Song" WHERE id = $1)
        LIMIT $2
      ),
      [song_id, limit]
    )
    res.map { |r| r.transform_keys(&:to_sym) }
  end
end

class SemanticSearch < RubyLLM::Tool
  description "Free-form semantic search. Generates an embedding from the description and finds matching songs. Use as fallback for nuanced queries."
  param :description, desc: "Natural language description of what the user wants"
  param :limit, type: :integer, required: false

  def execute(description:, limit: 5)
    embedding = RubyLLM.embed(description, model: "text-embedding-3-small").vectors
    embedding_str = "[#{embedding.join(',')}]"
    res = DB.exec_params(
      %(
        SELECT id, title, artist, mood
        FROM "Song"
        WHERE embedding IS NOT NULL
        ORDER BY embedding <=> $1::vector
        LIMIT $2
      ),
      [embedding_str, limit]
    )
    res.map { |r| r.transform_keys(&:to_sym) }
  end
end

# ─── AGENT ───────────────────────────────────────────────────────

class MusicAgent < RubyLLM::Agent
  model "gpt-4o-mini"
  instructions <<~PROMPT
    You are a friendly music recommendation agent for a streaming app called Sonara.

    Your job: take the user's natural-language request and recommend 3-5 songs from the library that match.

    You have these tools:
    - SearchByMood — for emotional/vibe requests ("sad", "happy", "chill")
    - SearchByBPM — when user mentions tempo or activity (running=140-170bpm, studying=60-90bpm, dancing=120-140bpm)
    - SearchByLyricalTheme — when user mentions topics ("songs about heartbreak", "rebellion")
    - FindSimilar — when user references a specific song they liked (need song id)
    - SemanticSearch — for nuanced, multi-faceted requests; use as fallback

    Strategy:
    1. Pick the most appropriate tool(s) based on the request
    2. You may call multiple tools and merge results if needed
    3. Briefly explain WHY each recommendation fits (1 sentence per song)
    4. ALWAYS return valid JSON with this exact shape:
       { "explanation": "short overall reasoning", "songs": [{ "id": "...", "title": "...", "artist": "...", "why": "..." }] }

    Be conversational but concise. Return only JSON, no extra text.
  PROMPT

  tools SearchByMood, SearchByBPM, SearchByLyricalTheme, FindSimilar, SemanticSearch
end

# ─── HTTP API ─────────────────────────────────────────────────────

post '/agent/query' do
  content_type :json
  body = JSON.parse(request.body.read.force_encoding('UTF-8'))
  query = body['query']

  halt 400, { error: 'query is required' }.to_json if query.nil? || query.strip.empty?

  agent = MusicAgent.new
  response = agent.ask(query)
  content = response.content.force_encoding('UTF-8')
  content
rescue => e
  status 500
  { error: e.message.encode('UTF-8', invalid: :replace, undef: :replace) }.to_json
end

get '/health' do
  content_type :json
  { status: 'ok' }.to_json
end
