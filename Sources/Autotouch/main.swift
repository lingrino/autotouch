import Foundation

// One binary, two roles:
//  - launched by launchd as the agent job (or with --agent, to run it in a terminal while
//    developing; stop the installed one first) → the gesture agent, forever
//  - launched any other way (opening Autotouch.app, `Autotouch --register` from `make install`)
//    → install or refresh the LaunchAgent, then exit. No UI either way.
signal(SIGPIPE, SIG_IGN)
if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == Agent.label || CommandLine.arguments.contains("--agent") {
    Agent.run()
}
exit(LaunchAgent.register(force: CommandLine.arguments.contains("--register")) ? 0 : 1)
