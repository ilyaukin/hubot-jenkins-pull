chai = require 'chai'
chaiAsPromised = require 'chai-as-promised'
chai.use(chaiAsPromised)
sinon = require 'sinon'
chai.use require 'sinon-chai'
rewire = require 'rewire'
util = require 'util'

expect = chai.expect

fail = (message) ->
  objDisplay = require 'chai/lib/chai/utils/objDisplay'
  formatArgs = (v for v in arguments).slice(1)
  throw new chai.AssertionError(message.replace /#\{(\d+)}/g, (s, pos) -> objDisplay(formatArgs[pos]))

createSpy = ->
  #    spy = sinon.spy()
  # actually, this sucks in error formatting, so implementing our own spy

  # @a stores args the spy called with
  @a = []
  @should = this
  @be = this
  @calledWith = ->
    for expectedArgument in arguments
      if @a.length == 0
        fail('expected #{0} but got nothing', expectedArgument)
      actualArgument = @a.shift()
      expect(actualArgument).equal(expectedArgument)
    if @a.length
      fail('got unexpected arguments #{0}', @a)
  func = (x) -> @a.push(x)
  for k, v of @
    func[k] = v
  func

class HttpMock
  constructor : (body) ->
    @err = null
    @res = {statusCode: 200}
    @body = body

  get : ->
    (f) =>
      f(@err, @res, @body)

class LoggerMock
  log : (msg) ->
    console.log(msg)

  trace : (msg) ->
    @log("TRACE   " + util.inspect msg)

  debug : (msg) ->
    @log("DEBUG   " + util.inspect msg)

  info : (msg) ->
    @log("INFO    " + util.inspect msg)

  warn : (msg) ->
    @log("WARNING " + util.inspect msg)

  error : (msg) ->
    @log("ERROR   " + util.inspect msg)

describe 'jenkins-pull', ->
  beforeEach ->
    @robot =
      respond: sinon.spy()
      hear: sinon.spy()
      logger: new LoggerMock()

    require('../src/jenkins-pull')(@robot)

    @module = rewire('../src/jenkins-pull')

    # Todo: maybe helpers can be defined not in beforeEach?
    # Todo: implement less monstrous way of checking async result
    @_checkLastSeenBuildNumber = (expected) ->
      check = (result) -> expect(result).to.be.equal(expected)
      Q = require 'q'
      deferred = Q.defer()
      setInterval =>
        result = @robot.brain.data.jenkins.history['/'].lastSeenBuildNumber
        deferred.resolve(result) if result
      , 10
      promise = deferred.promise
      Q.when(promise).then(check)

  it 'can match failed scenario report over pattern', ->
    grab = @module.__get__("grab")
    patterns = [
      {
        "pattern": [
          {"^\\s*Scenario": 1},
          {"^\\s*\x1B\\[32m": "*"},
          {"^\\s*\x1B\\[31m": 1},
          {"^\\s+": "*"}
        ]
      }
    ]
    @module.__set__("patterns", patterns)
    spy = createSpy()

    grab """
  Scenario Outline: Ololo
    \x1B[32mGiven passed step\x1B[0m
    \x1B[32mAnd one more passed step\x1B[0m
    \x1B[31mAnd failed step\x1B[0m

""",
      spy

    spy.should.be.calledWith """
  Scenario Outline: Ololo
    \x1B[32mGiven passed step\x1B[0m
    \x1B[32mAnd one more passed step\x1B[0m
    \x1B[31mAnd failed step\x1B[0m

"""

  it 'can match failed scenario report with multiline params over pattern', ->
    grab = @module.__get__("grab")
    patterns = [
      {
        "pattern": [
          {"^\\s*Scenario": 1},
          {"^\\s*\x1B\\[32m": "*"},
          {"^\\s+": "*"},
          {"^\\s*\x1B\\[31m": 1},
          {"^\\s+": "*"}
        ]
      }
    ]
    @module.__set__("patterns", patterns)
    spy = createSpy()
    grab """
  Scenario Outline: Ololo
    \x1B[32mGiven passed step\x1B[0m
    \x1B[32mAnd one more passed step with multiline data\x1B[0m
    \"\"\"
    taratam pam
    \"\"\"
    \x1B[31mAnd failed step\x1B[0m
""",
      spy

    spy.should.be.calledWith """
  Scenario Outline: Ololo
    \x1B[32mGiven passed step\x1B[0m
    \x1B[32mAnd one more passed step with multiline data\x1B[0m
    \"\"\"
    taratam pam
    \"\"\"
    \x1B[31mAnd failed step\x1B[0m

"""

  it 'should match several patterns in a row correctly', ->
    grab = @module.__get__("grab")
    patterns = [
      {
        "pattern": [
          {"^GOD": 1}
        ]
      }
    ]
    @module.__set__("patterns", patterns)
    spy = createSpy()
    grab """
NIEON
NKLJFFJ
GODJKLJLF
GODJL
LJKHFLJ
GOD KNHKL
KJHKJH
""",
      spy
    spy.should.be.calledWith "GODJKLJLF\n", "GODJL\n", "GOD KNHKL\n"

  it 'should match "+" notation for both single-line and multi-line blocks', ->
    grab = @module.__get__("grab")
    patterns = [
      {
        "pattern": [
          {"^PASS": "+"},
          {"\\s+": "*"}
        ]
      }
    ]
    @module.__set__("patterns", patterns)
    spy = createSpy()
    grab """
KHJKH
PASSSNKLH
NMNN
PASS KL
PASSJLO
PASS PA
KLJNKLN
KJNJ
""",
      spy
    spy.should.be.calledWith "PASSSNKLH\n", "PASS KL\nPASSJLO\nPASS PA\n"

  it 'should update last seen build number to max of not building build numbers', ->
    @robot.brain =
      data: {
        jenkins: {
          subscriptions: {
            '/': []
          }
        }
      }
    @robot.http = (url) ->
      {
        '/api/json': new HttpMock('{"builds": [{"url": "/1", "number": 1}, {"url": "/2", "number": 2}]}')
        '/1/api/json': new HttpMock('{"number": 1, "result": "", "building": false}')
        '/2/api/json': new HttpMock('{"number": 2, "result": "", "building": true}')
      }[url.split('?')[0]]
    pull = @module.__get__("pull")
    pull(@robot)
    @_checkLastSeenBuildNumber(1)

  it 'should remain last build number unchanged when no new builds', ->
    @robot.brain=
      data: {
        jenkins: {
          subscriptions: {
            '/': []
          },
          history: {
            '/': {lastSeenBuildNumber: 2}
          }
        }
      }
    @robot.http = (url) ->
      {
        '/api/json': new HttpMock('{"builds": [{"url": "/1", "number": 1}, {"url": "/2", "number": 2}]}')
        '/1/api/json': new HttpMock('{"number": 1, "result": "", "building": false}')
        '/2/api/json': new HttpMock('{"number": 2, "result": "", "building": false}')
      }[url.split('?')[0]]
    pull = @module.__get__("pull")
    pull(@robot)
    @_checkLastSeenBuildNumber(2)


