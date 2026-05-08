# music-agent

Ruby/Sinatra AI service powering the "Ask Sonara" feature. Uses Claude (via ruby_llm) with tool-calling to query the music database based on natural language.

## Stack

- Ruby + Sinatra
- ruby_llm gem (Anthropic Claude)
- pg gem (PostgreSQL direct connection)
- Deployed on Railway

## Tools

The agent has access to these database tools:

| Tool | Description |
|---|---|
| `SearchByMood` | Find songs by mood (happy, sad, energetic, calm, etc.) |
| `SearchByBPM` | Find songs within a BPM range |
| `SearchByGenre` | Find songs by genre |
| `SearchByArtist` | Find songs by artist name |
| `GetSongDetails` | Get full details for a specific song |

## API

```
GET  /health          → { "status": "ok" }
POST /agent/query     → { "query": "sad songs for a rainy day" }
                      ← { "answer": "...", "songs": [...] }
```

## Local Development

```bash
# Install gems
bundle install

# Set environment variables
export DATABASE_URL="postgresql://..."
export ANTHROPIC_API_KEY="sk-ant-..."
export PORT=4567

# Run
bundle exec ruby app.rb
```

## Railway Deployment

1. Push to Railway — it auto-detects Ruby via Gemfile
2. Set env vars: `DATABASE_URL`, `ANTHROPIC_API_KEY`
3. Railway injects `PORT` automatically — the app reads `ENV['PORT']`
4. Get public domain from Settings → Networking → Public Networking
5. Set `MUSIC_AGENT_URL=https://your-domain.up.railway.app` in Vercel

## Notes

- UTF-8 encoding is forced at the top of `app.rb` — required because Claude returns non-ASCII characters (smart quotes, em-dashes, accented letters) which crash Ruby's default US-ASCII encoding
- `set :protection, except: [:host_authorization]` is required to allow Railway's public domain (Rack::Protection blocks it by default)
- `set :bind, '0.0.0.0'` is required for Railway to route external traffic in
