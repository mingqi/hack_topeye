http = require 'http'
zlib = require 'zlib'
url = require 'url'
fs = require 'fs'
moment = require 'moment'
path = require 'path'
glob = require 'glob'

getRandomInt = (min, max) ->
  return Math.floor(Math.random() * (max - min + 1)) + min;
  
endswith = (s, suffix) ->
  return s[(s.length - suffix.length)...] == suffix


to_headers = (rawHeaders) ->
  i = 0
  name = []
  value = []
  headers = {}
  for h in rawHeaders
    if i % 2 == 0
      name.push h
    else
      value.push h
    i = i + 1
  for i in [0...name.length]
    headers[name[i]] = value[i]
  return headers


record = (data_dir, proxy) ->

  timestamp = null
  return (surl, method, headers, body, callback) ->
    if not fs.existsSync(data_dir)
      fs.mkdirSync(data_dir)

    proxy surl, method, headers, body, (res_status, res_headers, res_body) ->
      zlib.gunzip res_body, (err, result) ->
        res_json = result.toString()

        if endswith(surl, 'patient/verify_credentials')
          verify_file = path.join(data_dir, "verify-#{timestamp}.json")
          console.log "record verify data: #{verify_file}"
          fs.writeFileSync verify_file, result.toString()
          timestamp =  moment().format('YYYY-MM-DD-HH-mm')

        if endswith surl, 'patient/scheme'
          gid = /gidset=([0-9]+)/.exec(body)[1]
          pid = /pidset=([0-9]+)/.exec(body)[1]
          obj = JSON.parse(res_json)
          pattern_row = obj['data']['patternRows1'][0]
          game_row = obj['data']['gameRows1'][0]
          if pattern_row['pid'] != pid
            throw new Error("response pid #{pattern_row['pid']} is not equal request #{pid}")
          if game_row['gid'] != gid
            throw new Error("response pid #{game_row['gid']} is not equal request #{pid}")
          pattern_file = path.join(data_dir, "pattern-#{pid}-#{timestamp}.json")
          game_file = path.join(data_dir, "game-#{gid}-#{timestamp}.json")
          console.log "record game data: #{game_file}"
          console.log "record pattern data: #{pattern_file}"
          fs.writeFileSync pattern_file, JSON.stringify(pattern_row)
          fs.writeFileSync game_file, JSON.stringify(game_row)


        ## write raw data
        raw_file = path.join(data_dir, "raw-#{timestamp}.txt")
        console.log "record data in #{raw_file}"
        fs.appendFileSync(raw_file, "START: ------------------\n")
        fs.appendFileSync(raw_file, "REQUEST_URL: #{surl}\n")
        fs.appendFileSync(raw_file, "REQUEST_METHOD: #{method}\n")
        fs.appendFileSync(raw_file, "REQUEST_HEADER: #{JSON.stringify(headers)}\n")
        fs.appendFileSync(raw_file, "REQUEST_BODY: #{body.toString()}\n")
        fs.appendFileSync(raw_file, "RESPONSE_STATUS: #{res_status}\n")
        fs.appendFileSync(raw_file, "RESPONSE_HEADER: #{JSON.stringify(res_headers)}\n")
        fs.appendFileSync(raw_file, "RESPONSE_BODY: #{result.toString()}\n")
        fs.appendFileSync(raw_file, "EOF\n")

      callback(res_status, res_headers, res_body)


proxy_to = (surl, method, headers, body, callback) ->
  options = url.parse(surl)
  options.headers = headers
  options.method = method
  # console.log options
  request = http.request options, (target_res) ->
    target_status = target_res.statusCode
    target_headers = to_headers(target_res.rawHeaders)
    target_body = new Buffer(0)
    # console.log target_status
    # console.log target_headers
    target_res.on 'data', (chunk) ->
      target_body = Buffer.concat([target_body, chunk])
    target_res.on 'end', () ->
      callback target_status, target_headers, target_body
      # res.writeHead(target_status, target_headers)
      # res.end(target_body)
    
  request.write(body)
  request.end()
    

fake_proxy = (data_dir) ->
  timestamp = null
  return (surl, method, headers, body, callback) ->
    res_header = 
      'Content-Encoding': 'gzip'
      'Content-Type': 'text/html'
    if endswith(surl, 'patient/verify_credentials')
      verify_file_list = glob.sync(path.join(data_dir,"verify-*.json"))
      verify_file = verify_file_list[getRandomInt(0, verify_file_list.length - 1)]
      console.log "return verify data of #{verify_file}"
      timestamp = /verify-(.*).json/.exec(verify_file)[1]

      buff = fs.readFileSync(verify_file)
      zlib.gzip buff, (err, result) ->
        callback 200, res_header, result

    else if endswith(surl, 'patient/scheme')
      gid = /gidset=([0-9]+)/.exec(body)[1]
      pid = /pidset=([0-9]+)/.exec(body)[1]
      game_file = path.join(data_dir, "game-#{gid}-#{timestamp}.json")
      pattern_file = path.join data_dir, "pattern-#{pid}-#{timestamp}.json"
      body =
        'ret': 0,
        'msg': 'ok',
        'data':
          'patternRows1': [JSON.parse(fs.readFileSync(pattern_file, {'encoding': 'utf-8'}))]
          'patternRows2': []
          'gameRows1': [JSON.parse(fs.readFileSync(game_file, {'encoding': 'utf-8'}))]
          'gameRows2': []

      buff = new Buffer(JSON.stringify(body),'utf-8') 
      zlib.gzip buff, (err, result) ->
        callback 200, res_header, result

    else
      body =
        'ret': 0,
        'msg': 'ok',
        'data': {}
      buff = new Buffer(JSON.stringify(body),'utf-8') 
      zlib.gzip buff, (err, result) ->
        callback 200, res_header, result


http_proxy = (req, res, handler) ->
  req_headers = to_headers(req.rawHeaders)
  req_url = req.url
  req_method = req.method
  req_body = new Buffer(0)
  if req_url.indexOf('topeye.cn') <= 0
    res.end()
    return
  req.on 'data', (chunk) ->
    req_body = Buffer.concat([req_body, chunk])
  req.on 'end', () ->
    handler req_url, req_method, req_headers, req_body, (res_status, res_headers, res_body) ->
      res.writeHead(res_status, res_headers)
      res.end(res_body) 


[data_dir, mode] = process.argv[2...]
pp = null
if mode == 'record'
  pp = record(data_dir, proxy_to)
else
  pp = fake_proxy(data_dir)

proxy = http.createServer (req, res) ->
  http_proxy(req, res, pp)


proxy.listen 8899, () ->
  addr = proxy.address()
  console.log  "proxy listen on #{addr.address}:#{addr.port}"

