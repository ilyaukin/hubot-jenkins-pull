# hubot-jenkins-pull

A script for pulling non-blocking tests from Jenkins and notifying developers about errors

See [`src/jenkins-pull.coffee`](src/jenkins-pull.coffee) for full documentation.

## Installation

In hubot project repo, run:

`npm install hubot-jenkins-pull --save`

Then add **hubot-jenkins-pull** to your `external-scripts.json`:

```json
[
  "hubot-jenkins-pull"
]
```

## Sample Interaction

```
[18:08:23] Ilya Lyaukin: hubot subscribe http://jenkins.qa.local/job/Run-Tests-After-Build/
[18:08:24] Hubot: Subscribed 8:ilya.lyaukin to http://jenkins.qa.local/job/Run-Tests-After-Build/
```
