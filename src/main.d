import std.conv;

import vibe.d;
import temple;
import sdlang;

struct Config
{
	string name = "index";
	string[] address = ["127.0.0.1", "::1"];
	ushort port = 8080;
}
Config config;

shared static this()
{
	auto sdlConfig = parseFile("config.sdl");
	if("name"    in sdlConfig.tags) config.name    = sdlConfig.tags["name"   ][0].values[0].get!string;
	if("address" in sdlConfig.tags) config.address = sdlConfig.tags["address"][0].values.map!(a => a.get!string).array;
	if("port"    in sdlConfig.tags) config.port    = sdlConfig.tags["port"   ][0].values[0].get!int.to!ushort;

	// the router will match incoming HTTP requests to the proper routes
	auto router = new URLRouter();
	router.get("/", &index);
	// registers each method of WebInterface in the router
	//router.registerWebInterface(new WebInterface);
	// match incoming requests to files in the public/ folder
	router.get("*", serveStaticFiles("public/"));

	auto settings = new HTTPServerSettings;
	settings.port = config.port;
	settings.bindAddresses = config.address;
	listenHTTP(settings, router);
	logInfo(text("Please open http://", config.address[0], ":", config.port, "/ in your browser."));
}

void index(HTTPServerRequest req, HTTPServerResponse res)
{
	//res.writeBody("This is index");
	
	res.contentType = "text/html; charset=UTF-8";

	auto context = new TempleContext();
	context.name = config.name;

	//res.renderTemple!(`
	//	Hello, world!
	//	And hello, <%= var.name %>!
	//`)(context);
	res.renderTempleFile!(`index.html`)(context);
}
