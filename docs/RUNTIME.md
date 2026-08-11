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
The correct way to show a camera stream is to send the url to the chrome browser tab and then return to idle without checking the stream. I am able to see the stream immediately, which is what I want. You are not able to see the stream until some seconds after it has loaded, which may cause confusion because the stream has correctly loaded but you may perceive a failure. By that time, if I have not seen the stream, I will ask you to work on that, but almost always, the stream is ok. So just send the url to chrome and consider the job done, I will let you know if there is an error. Do not open any tabs now, just acknowledge that you understand these instructions.
```

This tells the agent to load a live stream.

```hermes
use the chrome-devtools mcp server to open a browser tab and begin playing the web player url from Monopoly.
```

