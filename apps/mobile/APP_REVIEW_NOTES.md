# App Review Notes for Hermes Go

Two paste blocks. No em dashes anywhere, because App Store Connect mangles
them. The Notes block is kept under the 4000 character limit of the App
Review Information field.

---

## BLOCK A: paste into App Review Information, then Notes

<!-- BEGIN NOTES BLOCK -->
WHAT THIS APP IS

Hermes Go is a client for a Hermes agent gateway the user runs on their own
computer, the same relationship an SSH client has with a server the user runs
themselves. We operate no backend. Target audience is developers and
technical users who already self-host a Hermes agent.

DEMO ACCESS (no server required)

A sample workspace is built into the app, so review needs no server.
1. Launch the app.
2. In "Gateway base URL", enter: demo.hermes.go
3. Tap Continue.
4. Username: demo
5. Password: demo
6. Tap Sign In.

Then: open a seeded chat from the drawer (menu icon, top left); send a
message and watch the reply stream with a live tool call; switch models from
the composer; open the Bots screen; open the Jobs tab and pause a job; open
Settings, then About.

It runs entirely on device on 127.0.0.1 and no network calls leave the
device. It is available to every user, not only reviewers, is documented in
Settings, then About, and the app does no reviewer detection. A "Sample" chip
shows while it is active so scripted replies cannot be mistaken for a real
agent.

BOTS

A bot is a saved configuration on the user's own gateway: a name, a model and
a set of instructions. Bots are created and stored by that server. The app
lists them and opens a chat against one.

APPLE HEALTH

Hermes Go clearly identifies this feature as "Apple Health" on the initial
connection screen and in Settings. It is off by default and opt-in.
Tap the Apple Health card on the first screen for the full in-app disclosure.
After entering the sample workspace, open Settings, then Apple Health, to see
the same disclosure and the sync controls. This row is visible in the sample
workspace even though sample data never leaves the device.

When the user turns sync on for a real gateway, iOS shows the standard Health
permission sheet and the user chooses which categories to allow. The app only
reads. It never writes or changes anything in Apple Health, which is what the
update purpose string states. Hermes Go uses HealthKit and does not use
CareKit.

Readings the user allows are sent to that user's own Hermes gateway, the
self-hosted server described above, so their health bot can summarize trends
for them. Health data is never sent to us, never shared with any third party,
and never used for advertising or marketing. We run no server that could
receive it. Turning the setting off stops the sync and clears its stored
state.

ACCOUNTS, PURCHASES, CONTENT

No account registration and no account deletion flow, because we run no
account system. The username and password are issued by the user's own
server. There are no purchases, subscriptions or paid content. No
user-generated content is shared between users, so there is nothing to report
or block. Chats are private to the user and their own server.

PERMISSIONS

Camera and photo library attach an image to a chat message. Microphone and
speech recognition provide voice dictation. Local network access reaches the
user's own gateway. Apple Health is covered above. All are optional and
requested only when the feature is used. The app requests no location,
contacts or calendar access, and performs no tracking.

EXTERNAL SERVICES

The app talks to one address: the gateway the user enters. We integrate no
analytics, advertising, crash reporting or tracking SDKs, and no payment
processor. It contacts no AI provider itself. Any AI service is configured by
the user on their own server. Apple speech recognition is used for dictation
and Apple text to speech for reading replies aloud.

REGIONS AND REGULATED INDUSTRY

The app functions identically in all regions, with no regional feature or
content differences. It is localized in nine languages. It provides no
regulated service and includes no protected third-party material.

NO VPN FUNCTIONALITY

This app is not a VPN and provides no network tunneling of any kind. It does
not link against NetworkExtension, does not use NEVPNManager or
NETunnelProvider, requests no VPN entitlement, and bundles no tunneling
library. It cannot route, proxy or observe any traffic other than its own
requests to the one gateway address the user typed in. It collects no
information through any tunnel because it creates none.

It makes ordinary HTTPS and WebSocket requests to that address, plus standard
local network access when it is on the user's own LAN, which is what
NSLocalNetworkUsageDescription covers.
<!-- END NOTES BLOCK -->

---

## BLOCK B2: reply to the Guideline 2.1 new-app information request

Answers the seven numbered items. Send with the screen recording attached.

<!-- BEGIN INFO REQUEST BLOCK -->
Thank you. Answers to all seven items follow.

1. SCREEN RECORDING

Attached. It was captured on a physical iPhone 17 Pro and begins with
launching the app. It shows the built in sample workspace being connected to
and signed in to, an existing chat opened, a message sent with the reply
streaming in including a live tool call, a new chat started, the model
switched, the Jobs tab with a scheduled job paused and resumed, and the
Settings screen.

The flows you listed that do not appear are absent because the app does not
have them:
- No account registration and no account deletion. We operate no account
  system. The username and password belong to the server the user runs.
- No purchases, subscriptions or paid content of any kind.
- No user-generated content shared between users, so there is no reporting or
  blocking mechanism to show. A chat is private to the user and their own
  server.
- Permission prompts do appear in the recording when the relevant feature is
  first used, for microphone and speech recognition when dictation is tapped.
  There is no App Tracking Transparency prompt because the app does no
  tracking.

2. DEVICES AND OPERATING SYSTEMS TESTED

- iPhone 17 Pro, iOS 27.0, physical device. Primary test device.
- iPad Air 11-inch (M4), iPadOS 27.0, Simulator. The full reviewer flow above
  was verified here as well, since your previous review used an iPad Air.

3. WHAT THE APP DOES, AND FOR WHOM

Hermes Go is a phone client for a Hermes agent gateway that the user runs on
their own computer. Hermes is an open source AI agent that people self host on
a home server, a workstation or a VPS.

The problem it solves: once you self host an agent, it is reachable only from
that machine. Hermes Go lets you reach your own agent from your phone, read
its replies as they stream, review what its scheduled jobs did, and reply
while away from your desk.

Target audience is developers and technical users who already self host a
Hermes agent. It is not a consumer chatbot and provides no AI service of its
own.

4. SETUP AND ACCESS

For review, no server is needed. A sample workspace is built into the app:
launch it, enter demo.hermes.go in "Gateway base URL", tap Continue, sign in
with username demo and password demo, then tap Sign In. Full steps and a tour
are in the App Review Information notes.

For a real user, setup is to run their own Hermes gateway and enter its
address, then sign in with credentials their own server issues. No sample
files are required.

5. EXTERNAL SERVICES, TOOLS AND PLATFORMS

The app itself contacts exactly one address: the gateway address the user
types in. It has no backend of ours.

- No analytics, advertising, attribution, crash reporting or tracking SDK.
- No payment processor.
- No AI provider is contacted by the app. Whether an AI service is used at
  all, and which one, is configured by the user on their own server. The app
  has no credentials for and no knowledge of any such service.
- Apple frameworks are used for two device features: Speech framework for
  voice dictation into the message box, and AVSpeechSynthesizer for reading a
  reply aloud.
- Third party code in the app is open source Flutter plugins providing device
  functionality only, for example keychain storage, local notifications, an
  on device SQLite cache, image picking and sharing. None transmits user data
  anywhere.

6. REGIONAL DIFFERENCES

There are none. The app functions identically in all regions, with the same
features and the same content everywhere. It is localized into English,
Arabic, German, Spanish, French, Japanese, Korean, Portuguese and Chinese.
Localization changes interface language only.

7. REGULATED INDUSTRY OR PROTECTED MATERIAL

Not applicable. Hermes Go is a network client for software the user runs
themselves. It operates in no regulated industry, provides no regulated
service, and contains no protected third party material. The name Hermes
refers to the open source Hermes agent this client connects to. The app is an
unofficial community built client, which is stated on its first screen, and it
is not presented as affiliated with any other party.

This information has also been added to the Notes field in App Review
Information.

Thank you,
Tom
<!-- END INFO REQUEST BLOCK -->

---

## BLOCK C: reply to Guideline 2.5.1 and 2.3.3, build 40

Attach a physical-device recording that follows the steps below, and replace
the bracketed App Store Connect screenshot confirmation before sending.

<!-- BEGIN HEALTHKIT SCREENSHOT REPLY BLOCK -->
Thank you for identifying both issues. I addressed them in build 40.

Guideline 2.5.1:
Hermes Go now clearly identifies its optional integration as "Apple Health"
directly on the initial connection screen, before sign-in, and again in
Settings. Tapping either entry explains that the feature works with the Apple
Health app, is off by default, reads only categories the user explicitly
authorizes, sends those samples only to the user's authenticated self-hosted
Hermes gateway, and never writes to the Apple Health app. The implementation
uses HealthKit and does not use CareKit.

The attached recording was captured on a physical iPhone. It shows:
1. Launching Hermes Go and tapping Apple Health on the first screen.
2. The complete Apple Health disclosure.
3. Entering the built-in sample workspace using demo.hermes.go / demo / demo.
4. Opening Settings, then Apple Health, where the disclosure and
   sync controls are clearly visible.

Guideline 2.3.3:
[I replaced the 13-inch iPad screenshots. The majority now show the actual app
in use, including a live chat, Bot Mode, jobs, and Settings. I removed
promotional images that did not depict the application UI.]

Thank you,
Tom
<!-- END HEALTHKIT SCREENSHOT REPLY BLOCK -->

### App Store description insertion for build 40

Add this under WHAT YOU CAN DO so the marketing text also identifies the
integration, as required by Guideline 2.5.1:

• On iPhone and iPad, optionally sync health data you authorize from the Apple
Health app to your authenticated, self-hosted gateway for bounded bot summaries.
Hermes Go reads only, never writes to the Apple Health app, and the feature is
off by default.

---

## BLOCK B: reply to the Guideline 2.1(a) message about a demo authentication code

Submission ID cef05d7f-02cd-4c0a-884d-abe10b3daebd, reviewed August 05 2026.
This is the message asking for an authentication code and offering a call.

<!-- BEGIN AUTHCODE REPLY BLOCK -->
Thank you for the review, and for setting out the options.

There is no authentication code for this app, and none exists to give you. I
can see why the previous build looked as though there was one, and I am sorry
for the wasted round trip.

Hermes Go is a client for a Hermes agent gateway that the user runs on their
own computer, in the same way an SSH client or a NAS app connects to a server
the user runs themselves. The first field on the connect screen asks for that
server's address, not for a code. The username and password are issued by the
user's own server. In build 5 we supplied credentials but no reachable server,
so there was nothing for the reviewer to sign in to and no way past the first
screen. That was our mistake.

We have taken the third option you recommended, "including a demonstration
mode that exhibits the app's full features and functionality". It is bundled
in the new build and needs no server, no code and no network access.

To sign in:
1. Launch the app.
2. On the connect screen, in "Gateway base URL", enter: demo.hermes.go
3. Tap Continue.
4. Username: demo
5. Password: demo
6. Tap Sign In.

That gives you a fully working sample workspace with existing chat history.
You can send messages and watch replies stream in with live tool calls, start
new chats, switch models, browse the slash command reference and the skills
catalog, and pause or resume scheduled jobs. A suggested tour is in the App
Review Information notes for this version.

The sample workspace runs entirely on the device, on 127.0.0.1, and no network
calls leave the device. It is available to every user, not only to reviewers:
the same host and credentials work for anyone, it is documented in the app
under Settings, then About, and the app performs no reviewer detection of any
kind. A "Sample" chip is shown while it is active so that its scripted replies
can never be mistaken for a real agent.

A call should not be necessary, since there is no code to convey. If anything
in the sample workspace does not behave as described, please tell me what you
saw and I will fix it promptly.

Thank you,
Tom
<!-- END AUTHCODE REPLY BLOCK -->

---

## BLOCK C: reply to the earlier VPN message

<!-- BEGIN REPLY BLOCK -->
Thank you for the review.

Regarding the VPN question, Hermes Go has no VPN functionality of any kind:

- It does not use NetworkExtension, NEVPNManager or NETunnelProvider.
- It requests no VPN entitlement and bundles no tunneling library. There is
  no WireGuard, no OpenVPN and no proprietary tunnel code.
- Its only network operations are ordinary HTTPS and HTTP requests plus a
  single WebSocket connection to a gateway address the user supplies, and
  standard local network access to reach that gateway on the user's own LAN,
  governed by NSLocalNetworkUsageDescription.

To answer the three specific questions: the app collects no user information
using VPN, because it has no VPN functionality. There is therefore no purpose
for which such data is collected, and no data is shared with any third party.
Chat messages travel directly between the user's device and the user's own
self-hosted gateway. We operate no server in that path.

We believe the automated analysis flagged the app because the word "VPN"
appears in user-facing text. Every occurrence is guidance about the user's own
network, never a feature we ship. The complete list:

1. NSLocalNetworkUsageDescription: "Hermes Go connects to your Hermes agent
   gateway on the local network or VPN."
2. Three connection status messages, shown when the user's own gateway is
   unreachable or is being reached over plain HTTP:
   "Auto-reconnect gave up. Tap Reconnect (or check VPN / host)."
   "Cannot reach the gateway. Check VPN/Tailscale and host power."
   "Unencrypted HTTP: fine on your own LAN or VPN, use HTTPS for anything
   public."
3. Our developer documentation, which recommends that a user who wants to
   reach their self-hosted gateway from outside their home network do so over
   a private network rather than a port forward.

All of these describe networking the user may already have configured,
typically Tailscale, a third party product that we do not bundle, link
against, install, configure or control. The app has no awareness of whether
such software is present. This is the same pattern as an SSH client or a NAS
app documenting that you can reach your own server over your own VPN if you
choose to.

Regarding demo access, we have added a sample workspace to the build so that
review can proceed without setting up a server. Full sign-in steps and a
suggested tour are in the App Review Information notes for this version.

Thank you,
Tom
<!-- END REPLY BLOCK -->
