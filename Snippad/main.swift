import Foundation

// `Snippad --mcp` is the stdio end of the MCP server: agents start it, and it
// relays to the running app (starting it first if need be). Anything else is
// the app.
if CommandLine.arguments.dropFirst().contains("--mcp") {
    MCPBridge.run()
} else {
    SnippadApp.main()
}
