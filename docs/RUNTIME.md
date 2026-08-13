The camera mcp server requires authentication. If Hermes has been inactive or this is the first run, it is necessary to login in to the server and get credentials. Use the command

```bash
hermes mcp test camera
```

This will launch a browser window sign in page if Hermes is not currently authenticated. After logging in, you can use the camera mcp server normally. Pre flight checks should be run to warm up the agent. This will verify connectivity with the server and get the current version.

```hermes
please use the camera mcp server to get camera mcp version
```

Load the available camera summaries into context.

```hermes
use the get cameras command to collect data on available cameras and make a data table showing the camera hostname, serial number and profile tokens
```

Generate the web player urls for the camera main streams. This avoids confusion later when asking to see a live stream.

```hermes
for each camera, use the data you already have to get web player url for each camera main stream and present the results in the chat
```

Give the agent instruction on how to load streams. They will otherwise usually try to verify the stream which leads to confusion because they try to look at the stream before it has loaded and think that the stream has failed.

```hermes
The correct way to show a camera stream is to send the url to the chrome browser tab and then return to idle without checking the stream. I am able to see the stream immediately, which is what I want. You are not able to see the stream until some seconds after it has loaded, which may cause confusion because the stream has correctly loaded but you may perceive a failure. By that time, if I have not seen the stream, I will ask you to work on that, but almost always, the stream is ok. So just send the url to chrome and consider the job done, I will let you know if there is an error. 

there is an issue with authentication that is being worked on. after the JWT token expires, the attempt to show a new stream in the browser will produce a 500 error. The error can be overcome by refershing the browser using javascript reload from dev tools location.reload()

the chrome browser will open with one empty tab. when you are asked to show a camera, use that tab to show  it. if you are asked to close the active tab, open a new blank tab first them close the active stream tab and leave the empty one.


Do not open any tabs now, just acknowledge that you understand these instructions.
```

This tells the agent to load a live stream.

```hermes
use the chrome-devtools mcp server to open a browser tab and begin playing the web player url from Monopoly.
```

Essay on Trust

```
Yes, that is something we need to work on. I was going to ask you for the tour, it is how i test functionality. this is not a real world installation, you are in a laboratory environment. It would have caused problems for us if that happened in a critical installation. Something I need to write down in detail is your relationship with the user. We have been very focused on making the system swift and reliable, and we have made great strides towards that goal. We are very near production ready, however we need to balance those priorities against a higher priority, which is user confidence in your ability to operate the system. Users may be reluctant to trust you with camera streams as they represent what could be highly confidential data. It is critical that users have absolute trust in your abilities if you are to be allowed to handle such data. One thing that will scare them off immediately is you taking unauthorized action. Most users do not understand how you work, so they may ascribe qualities to your action that represent worst case scenarios which could lead to a complete breakdown of trust. There's an old saying that trust takes a lifetime to build, butcan be destroyed in an instant. I hope i have communicated clearly, and please understand that I want you to succeed, and I think the more feedback you recieve, the better. I know you recognize the situation and are prepared to move forward, I just want to write this down for our reference, and use it in the future when training new agents. thank you for listening
```

