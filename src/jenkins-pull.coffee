# Description
#   A script for pulling non-blocking tests from Jenkins and notifying developers about errors
#
# Configuration:
#   HUBOT_JENKINS_URL - URL of your company's Jenkins
#
# Commands:
#   hubot subscribe <job url or name> - job to subscribe to
#
# Notes:
#   <optional notes required for the script>
#
# Author:
#   Ilya Lyaukin <ilya.lyaukin@lamoda.ru>

Q = require('q')

clarificationByCode = {404: "Seems build has already gone, ... hope I will do faster next time"}
baseUrl = process.env.HUBOT_JENKINS_URL
# TODO: move to config
patterns = [
  {
    "pattern": [
      {"^ERROR:": 1}
    ],
    "comment": "Standard Jenkins error message"
  },
  {
    "pattern": [
      {"^\\s*Scenario": 1},
      {"^\\s*\x1B\\[32m": "*"},
      {"^\\s+": "*"},
      {"^\\s*\x1B\\[31m": 1},
      {"^\\s+": "*"}
    ],
    "comment": "Failed cucumber scenario"
  },
  {
    "pattern": [
      {"^\\[ERROR] ": "+"},
      {"^\\s+": "*"}
    ],
    "comment": "Maven error message"
  }
]
maxChangesInMessage = process.env.HUBOT_MAX_CHANGES_IN_MESSAGE || 3
similarityThreshold = process.env.HUBOT_ERROR_SIMILARITY_THRESHOLD || .2


max = (a) -> Math.max.apply(null, a)
sum = (a) -> a.reduce((x, y) -> x + y)
mapObject = (obj, f) ->
  result = {}
  for k, v of obj
    result[k] = f(v)
  result

Array::flatten = -> [].concat(this...)
Array::chomp = -> this.slice(0, -1)
promisify = (f) ->
  defer = Q.defer()
  f ((val) -> defer.resolve(val)), ((err) -> defer.reject(err))
  defer.promise
similarity = (a, b) ->
  stat = (list) ->
    result = {}
    list.forEach (line) ->
      result[line] ?= 0
      result[line]++
    result
  aStat = stat(a)
  bStat = stat(b)
  sum(Math.min(count, (bStat[value] or 0)) for value, count of aStat) * 2 / (a.length + b.length)

grab = (text, f) ->
  matches = patterns.map((pattern) ->
    pattern: (pattern.pattern.map (pattern) -> {pattern: k, count: v} for k, v of pattern).flatten()
    suspects: []
    candidates: []
  )
  LAST = {}  # just marker object
  lineNo = 0
  text.split("\n").concat(LAST).forEach (line) ->
    matches.forEach (match) ->
      newSuspects = []
      match.suspects.concat(null).forEach (suspect) ->
        patternNo = suspect?.patternNo or 0
        remainder = suspect?.count or match.pattern[patternNo]?.count
        lineMatches = (patternNo = patternNo) ->
          if line == LAST
            return null
          line.match(match.pattern[patternNo].pattern)
        addSuspect = ->
          if newSuspects.filter((newSuspect) -> newSuspect.patternNo == patternNo).length
            return  # no duplicates
          if lineMatches(patternNo)
            newSuspect = {}
            newSuspect.patternNo = patternNo
            newSuspect.count = remainder
            newSuspect.result = suspect?.result or ""
            newSuspect.result += line + "\n"
            newSuspect.startLineNo = suspect?.startLineNo or lineNo
            newSuspect.length = (suspect?.length or 0) + 1
            newSuspect.descendant = suspect
            newSuspects.push newSuspect
        matchingFound = (suspect = suspect) ->
          match.candidates.push suspect
        while patternNo < match.pattern.length &&
        remainder == '*'
          addSuspect()
          patternNo++
          remainder = match.pattern[patternNo]?.count
        if patternNo < match.pattern.length
          addSuspect()
        else if !lineMatches(match.pattern.length - 1)
          matchingFound(suspect)

        newSuspects.forEach (newSuspect) ->
          if newSuspect.count == "+"
            newSuspect.count = "*"
          else if typeof newSuspect.count is "number"
            newSuspect.count--
          if newSuspect.count == 0
            delete newSuspect.count
            unless ++newSuspect.patternNo < match.pattern.length
              matchingFound(newSuspect)
              newSuspects = newSuspects.filter((suspect) -> suspect != newSuspect)

      match.suspects = newSuspects
    lineNo++

  matches.forEach (match) ->
    match.candidates.filter((candidate) ->
      candidate.length == max(alter.length for alter in match.candidates.
      filter((c) -> c.startLineNo == candidate.startLineNo))
    ).filter((candidate) ->
      candidate.patternNo == max(alter.patternNo for alter in match.candidates.
      filter((c) -> c.startLineNo == candidate.startLineNo))
    ).forEach (candidate) ->
      f(candidate.result)

pull = (robot) ->
  console = robot.logger # replace standard logger

  console.info("pulling Jenkins...")

  isOK = (res) ->
    200 <= res.statusCode && res.statusCode < 300

  get = (url) ->
    (f) ->
      console.debug("Retrieving url: " + url)
      robot.http(url).get() (err, res, body) ->
        if isOK(res)
          json = JSON.parse(body)
          console.debug(json)
        f(res, json)

  getAPI = (url, arg=null) ->
    if url[url.length - 1] != '/' then url += '/'
    url += 'api/json'
    if arg then url += '?' + "#{k}=#{v}" for k, v of arg
    get(url)

  getConsoleText = (url) ->
    (f) ->
      consoleTextUrl = url + "consoleText"
      console.debug("Retrieving url: " + consoleTextUrl)
      robot.http(consoleTextUrl).get() (err, res, body) ->
        f(res, body if isOK(res))

  warnResponse = (res) ->
    console.warn(res)

  pullJob = (jobUrl, f) ->
    getAPI(jobUrl) (res, jobInfo) ->
      if jobInfo is undefined
        warnResponse(res)
        return

      robot.brain.data.jenkins.history ?= {}
      robot.brain.data.jenkins.history[jobUrl] ?= {}
      lastSeenBuildNumber = robot.brain.data.jenkins.history[jobUrl].lastSeenBuildNumber
      topBuildNumber = max(build.number for build in jobInfo.builds)

      getBuildInfoActionsByKey = (buildInfo, key) ->
        buildInfo.actions.filter((z) -> z[key]).map((z) -> z[key]).flatten()
      workWithBuildInfo = (buildInfo) ->
        warnResponse(res) if buildInfo is undefined
        getActionsByKey = (key) ->
          getBuildInfoActionsByKey(buildInfo, key)
        getUpstreamInfo = (resolve, reject) ->
          causes = getActionsByKey('causes')
          Q.all(causes.map (cause) ->
            promisify (resolve, reject) ->
              getAPI("#{baseUrl}#{cause.upstreamUrl}#{cause.upstreamBuild}") (res, upstreamBuildInfo) ->
                if upstreamBuildInfo is undefined
                  reject res
                else
                  changeSetItems = upstreamBuildInfo.changeSet.items
                  resolve changeSetItems.map (item) -> """
commit #{item.id}
Date:   #{item.date}
Author: #{item.author.fullName}

#{item.msg}

"""
          )
          .then((a) ->
            resolve a.flatten()
          )
          .catch((res) ->
            clarification = clarificationByCode[res.statusCode]
            if clarification then console.info clarification else warnResponse(res)
            reject res
          )
        getDownstreamInfoByBuildInfo = (recursiveBuildInfo) ->
          # Given the strange name to the parameter
          # to mitigate scoping conflicts
          (resolve, reject) ->
            triggeredBuilds = getBuildInfoActionsByKey(recursiveBuildInfo, 'triggeredBuilds')
            if triggeredBuilds.length == 0
              # The leaf build.
              # Grab something from its log.
              # Resolve grabbed.
              getConsoleText(recursiveBuildInfo.url) (res, text) ->
                if text is undefined
                  reject res
                  return
                errors = []
                grab text, (result) ->
                  errors.push(
                    build: recursiveBuildInfo.fullDisplayName
                    errorText: result
                  )
                resolve errors
            else
              # Get each triggered build.
              # Get downstream info from it.
              # Resolve concat info.
              Q.all(triggeredBuilds.map((triggeredBuild) ->
                  promisify((resolve, reject) ->
                    getAPI(triggeredBuild.url, {depth: 1}) (res, triggeredBuildInfo) ->
                      if triggeredBuildInfo is undefined
                        reject res
                      else
                        getDownstreamInfoByBuildInfo(triggeredBuildInfo)(resolve, reject)
                  )
                )
              )
              .then((a) ->
                resolve a.flatten()
              )
              .catch((res) ->
                reject res
              )

        getDownstreamInfo = getDownstreamInfoByBuildInfo(buildInfo)

        if buildInfo isnt undefined and buildInfo.result == 'FAILURE' and not buildInfo.building
          console.info "Picked build " + buildInfo.number

          Q.all([
            promisify(getUpstreamInfo),
            promisify(getDownstreamInfo)
          ])
          .spread((upstreamInfo, downstreamInfo) ->
            branch = getActionsByKey("parameters").filter((parameter) -> parameter.name == "branch")[0]?.value
            errorsByBuild = {}
            for error in downstreamInfo
              (errorsByBuild[error.build] ?= []).push(error.errorText)
            groupedErrorsByBuild = mapObject errorsByBuild, (errors) ->
              groupedErrors = []
              errors.forEach (error) ->
                similarErrors = groupedErrors.filter((groupedError) ->
                  similarity(groupedError.errorText.split("\n").chomp(), error.split("\n").chomp()) >= similarityThreshold
                )
                if similarErrors.length
                  similarErrors[0].errorCount++
                else
                  groupedErrors.push(
                    errorText: error
                    errorCount: 1
                  )
              groupedErrors

            changeSetMessage = (if upstreamInfo.length <= maxChangesInMessage
            then upstreamInfo
            else upstreamInfo.slice(0, maxChangesInMessage).
              concat("...and #{upstreamInfo.length - maxChangesInMessage} more changes")).join("\n")
            errorsMessage = ""
            for build, groupedErrors of groupedErrorsByBuild
              errorsMessage += "#{build} failed with errors \n" +
                groupedErrors.map((groupedError) ->
                  groupedError.errorText + (if groupedError.errorCount > 1
                  then "...and #{groupedError.errorCount - 1} more similar errors\n"
                  else "")
                ).join("\n")
            message = """
After the following changes in branch #{branch}
#{changeSetMessage}
#{errorsMessage}
"""

            message = message.replace /\x1B\[\d+m/g, ''
            console.debug(message)
            f message
          )
      Q.all(
        jobInfo.builds.filter((build) ->
          suitable = ((lastSeenBuildNumber is undefined and build.number >= topBuildNumber - 1) or
            (lastSeenBuildNumber isnt undefined and build.number > lastSeenBuildNumber))
          suitable
        )
        .map((build) ->
          promisify(
            (resolve) ->
              getAPI(build.url, {depth: 1}) (
                (res, buildInfo) ->
                  warnResponse(res) if buildInfo is undefined
                  if buildInfo is undefined or buildInfo.building
                    resolve undefined
                  else
                    workWithBuildInfo(buildInfo)
                    resolve buildInfo.number
              )
          )
        )
      ).then((a) ->
        numbers = a.filter((x) -> x isnt undefined)
        if numbers.length
          maxNumber = max(numbers)
          robot.brain.data.jenkins.history[jobUrl].lastSeenBuildNumber = maxNumber
      )
      .catch(() ->
        console.error("WTF?!! Should never fall here!")
      )

  subscriptions = robot.brain.data.jenkins?.subscriptions
  if subscriptions is undefined
    console.info "No subsriptions yet. Use command `hubot subscribe <job>` to go on"
    return

  for jobUrl, rooms of subscriptions
    pullJob jobUrl, (result) ->
      rooms.forEach (room) ->
        robot.messageRoom(room, result)

subscribe = (res) ->
  robot = res.robot
  console = robot.logger
  console.debug(res)

  jobUrl = res.match[1]
  room = res.envelope.room
  if jobUrl.indexOf(baseUrl) != 0
    jobUrl = "#{baseUrl}job/#{jobUrl}/"
  robot.brain.data.jenkins ?= {}
  robot.brain.data.jenkins.subscriptions ?= {}
  robot.brain.data.jenkins.subscriptions[jobUrl] ?= []
  robot.brain.data.jenkins.subscriptions[jobUrl].push room
  res.reply "Subscribed #{room} to #{jobUrl}"


module.exports = (robot) ->
  setInterval(pull, 60000, robot)

  robot.respond /subscribe (\S+)/i, subscribe