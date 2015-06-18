require_relative '../lib/sony-ci-api/sony_ci_admin'
require 'webmock/rspec'
require 'yaml'
require 'tmpdir'

describe 'Mock Sony Ci API' do
  CREDENTIALS = YAML.load_file(File.expand_path('../../config/ci.yml.sample', __FILE__))
  ACCESS_TOKEN = '32-hex-access-token'
  ASSET_ID = 'asset-id'
  OAUTH = {'Authorization' => "Bearer #{ACCESS_TOKEN}"}
  DETAILS = {'id' => ASSET_ID, 'name' => 'video.mp3'}
  LOG_RE = /^\d{4}-\d{2}-\d{2}.*\t(large|small)-file\.txt\tasset-id\t\{"id"=>"asset-id", "name"=>"video\.mp3"\}\n$/
  
  def stub_details
    stub_request(:get, "https://api.cimediacloud.com/assets/#{ASSET_ID}").
      with(headers: OAUTH).
      to_return(status: 200, headers: {}, body: JSON.generate(DETAILS))
  end
  
  before(:each) do
    # I don't really understand the root problem, but
    # before(:all) caused the second test to fail, even with .times(x)
    
    WebMock.disable_net_connect!
    
    user_password = "#{URI.encode(CREDENTIALS['username'])}:#{URI.encode(CREDENTIALS['password'])}"
    
    stub_request(:post, "https://#{user_password}@api.cimediacloud.com/oauth2/token").
      with(body: URI.encode_www_form(
                  'grant_type' => 'password',
                  'client_id' => CREDENTIALS['client_id'],
                  'client_secret' => CREDENTIALS['client_secret'])).
      to_return(status: 200, headers: {}, body: <<-EOF
        {
          "access_token": "#{ACCESS_TOKEN}",
          "expires_in": 3600,
          "token_type": "bearer",
          "refresh_token": "32-hex-which-we-are-not-using"
        }
        EOF
      )
  end
  
  after(:all) do
    WebMock.disable!
  end
  
  it 'does OAuth' do
    ci = SonyCiAdmin.new(credentials: CREDENTIALS)
    expect(ci.access_token).to eq ACCESS_TOKEN
  end
  
  describe 'uploads' do
    it 'does small files' do
      ci = SonyCiAdmin.new(credentials: CREDENTIALS)    
      Dir.mktmpdir do |dir|
        log_path = "#{dir}/log.txt"
        path = "#{dir}/small-file.txt"
        File.write(path, "doesn't matter")

        stub_request(:post, "https://io.cimediacloud.com/upload").
          with(body: URI.encode_www_form(
                'filename' => path,
                'metadata' => "{\"workspaceId\":\"#{CREDENTIALS['workspace_id']}\"}"),
               headers: OAUTH).
          to_return(status: 200, headers: {}, body: "{\"assetId\":\"#{ASSET_ID}\"}")

        # After upload we get details for log:
        stub_details

        ci_id = ci.upload(path, log_path)
        expect(ci_id).to eq ASSET_ID
        expect(File.read(log_path)).to match LOG_RE
      end
    end
    
    it 'does big files' do
      ci = SonyCiAdmin.new(credentials: CREDENTIALS)    
      Dir.mktmpdir do |dir|
        log_path = "#{dir}/log.txt"
        name = 'large-file.txt'
        path = "#{dir}/#{name}"
        size = SonyCiAdmin::Uploader::CHUNK_SIZE * 2
        File.write(path, 'X' * size)

        stub_request(:post, 'https://io.cimediacloud.com/upload/multipart').
          with(body: "{\"name\":\"#{name}\",\"size\":#{size},\"workspaceId\":\"#{CREDENTIALS['workspace_id']}\"}",
               headers: OAUTH.merge({'Content-Type'=>'application/json'})).
          to_return(status: 201, body: "{\"assetId\": \"#{ASSET_ID}\"}", headers: {})

        (1..2).each do |i|
          stub_request(:put, "https://io.cimediacloud.com/upload/multipart/#{ASSET_ID}/#{i}").
             with(body: 'X' * SonyCiAdmin::Uploader::CHUNK_SIZE,
                  headers: OAUTH.merge({'Content-Type'=>'application/octet-stream', 'Expect'=>''})).
             to_return(status: 200, body: "", headers: {})
        end

        stub_request(:post, "https://io.cimediacloud.com/upload/multipart/asset-id/complete").
           with(headers: OAUTH).
           to_return(status: 200, body: "", headers: {})

        # After upload we get details for log:
        stub_details

        ci_id = ci.upload(path, log_path)
        expect(ci_id).to eq ASSET_ID
        expect(File.read(log_path)).to match LOG_RE
      end
    end
  end
  
  it 'does list' do
    ci = SonyCiAdmin.new(credentials: CREDENTIALS)
    limit = 10
    offset = 20
    list = [{"kind"=>"asset", "id"=>ASSET_ID}] # IRL there is more here.
    
    stub_request(:get, "https://api.cimediacloud.com/workspaces/#{CREDENTIALS['workspace_id']}/contents?limit=#{limit}&offset=#{offset}").
      with(headers: OAUTH).
      to_return(status: 200, headers: {}, body: <<-EOF
        {
          "limit": #{limit},
          "offset": #{offset},
          "count": 1,
          "items": #{JSON.generate(list)}
        }
        EOF
      )
      
    expect(ci.list(limit, offset)).to eq list
  end
  
  it 'does details' do
    ci = SonyCiAdmin.new(credentials: CREDENTIALS)
    
    stub_details
    
    expect(ci.detail(ASSET_ID)).to eq DETAILS
  end
  
  it 'does delete' do
    ci = SonyCiAdmin.new(credentials: CREDENTIALS)
    
    stub_request(:delete, "https://api.cimediacloud.com/assets/#{ASSET_ID}").
      with(headers: OAUTH).
      to_return(status: 200, headers: {}, body: 'IRL JSON response goes here.')
    
    expect { ci.delete(ASSET_ID) }.not_to raise_exception
  end
  
  it 'does download' do
    ci = SonyCiAdmin.new(credentials: CREDENTIALS)
    
    temp_url = 'https://s3.amazon.com/ci/temp-url.mp3'
    
    stub_request(:get, "https://api.cimediacloud.com/assets/#{ASSET_ID}/download").
      with(headers: OAUTH).
      to_return(status: 200, headers: {}, body: JSON.generate({ 'location' => temp_url }))
    
    expect(ci.download(ASSET_ID)).to eq temp_url
  end
  
  describe 'exceptions' do
    it 'throws exception for 400' do
      BAD_ID = 'bad-id'
      ci = SonyCiAdmin.new(credentials: CREDENTIALS)

      stub_request(:get, "https://api.cimediacloud.com/assets/#{BAD_ID}/download").
        with(headers: OAUTH).
        to_return(status: 400, headers: {})

      expect { ci.download(BAD_ID) }.to raise_error
    end
  end
end
