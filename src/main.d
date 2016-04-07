import std.conv;

import vibe.d;
import temple;
import sdlang;

struct Config
{
	string name = "index";
	string[] address = ["127.0.0.1", "::1"];
	ushort port = 8080;
	string passHash; // SHA256
}
Config config;

immutable passFieldName = "REPORTING_SERVER_PASS";

shared static this()
{
	auto sdlConfig = parseFile("config.sdl");
	if("name"    in sdlConfig.tags) config.name    = sdlConfig.tags["name"   ][0].values[0].get!string;
	if("address" in sdlConfig.tags) config.address = sdlConfig.tags["address"][0].values.map!(a => a.get!string).array;
	if("port"    in sdlConfig.tags) config.port    = sdlConfig.tags["port"   ][0].values[0].get!int.to!ushort;
	if("pass-hash-sha256" in sdlConfig.tags) config.passHash = sdlConfig.tags["pass-hash-sha256"][0].values[0].get!string;

	// the router will match incoming HTTP requests to the proper routes
	auto router = new URLRouter();
	router.get("/", &index);
	//router.get("/compiler", &compiler);
	router.post("/compiler", &compiler);
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
	res.contentType = "text/html; charset=UTF-8";

	auto context = new TempleContext();
	context.name = config.name;

	res.renderTempleFile!(`index.html`)(context);
}

bool checkPassword(HTTPServerRequest req, HTTPServerResponse res)
{
	import std.digest.sha;
	if(passFieldName in req.form)
	{
		auto receivedHash = sha256Of(req.form[passFieldName]).toHexString()[];
		if(lengthConstantEquals(cast(const ubyte[])receivedHash.toUpper(), cast(const ubyte[])config.passHash.toUpper()))
			return true;
	}

	res.statusCode = 403;
	res.writeBody("403 - forbidden\n");
	logInfo("Rejected");
	return false;
}

void compiler(HTTPServerRequest req, HTTPServerResponse res)
{
	if(!checkPassword(req, res))
		return;
	
	logInfo("Got valid POST");
	foreach(key, val; req.form)
	if(key != passFieldName)
		logInfo(text("  ", key, ": ", val));

	res.writeBody("Ok, pretending to add new compiler\n");
//	res.contentType = "text/html; charset=UTF-8";

}

/++
Compare two arrays in "length-constant" time. This thwarts timing-based
attacks by guaranteeing all comparisons (of a given length) take the same
amount of time.

See the section "Why does the hashing code on this page compare the hashes in
"length-constant" time?" at:
    $(LINK https://crackstation.net/hashing-security.htm)
+/
bool lengthConstantEquals(const ubyte[] a, const ubyte[] b)
{
	auto diff = a.length ^ b.length;
	for(int i = 0; i < a.length && i < b.length; i++)
		diff |= a[i] ^ b[i];

	return diff == 0;
}
