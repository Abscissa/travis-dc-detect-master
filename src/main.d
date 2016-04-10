import std.conv;
import std.datetime;
import std.file;
import std.path;
import std.stdio;

import vibe.vibe;
import vibe.core.connectionpool;
import mysql.db;
import temple;
import sdlang;

import dcompiler;

alias write = std.stdio.write;

struct Config
{
	string name = "index";
	string[] address = ["127.0.0.1", "::1"];
	ushort port = 8080;
	string passHash; // SHA256

	string dbHost;
	ushort dbPort;
	string dbName;
	string dbUser;
	string dbPass;
	string dbAdminUser;
	string dbAdminPass;
	string dbAdminNewUserHost;
}
Config config;

immutable passFieldName = "REPORTING_SERVER_PASS";

immutable dbInitUserSql = "
DROP USER IF EXISTS '$DB_USER'@'$DB_ADMIN_NEW_USER_HOST';
CREATE USER '$DB_USER'@'$DB_ADMIN_NEW_USER_HOST' IDENTIFIED BY '$DB_PASS';
GRANT SELECT,INSERT,UPDATE,DELETE ON `$DB_NAME`.* TO '$DB_USER'@'$DB_ADMIN_NEW_USER_HOST';
FLUSH PRIVILEGES;
";
 
immutable dbInitSchemaSql = "
DROP DATABASE IF EXISTS `$DB_NAME`;
CREATE DATABASE `$DB_NAME`;

DROP TABLE IF EXISTS `$DB_NAME`.`compilers`;
CREATE TABLE `$DB_NAME`.`compilers` (
	`type`            VARCHAR(255) NOT NULL,
	`typeRaw`         VARCHAR(255) NOT NULL,
	`compilerVersion` VARCHAR(255) NOT NULL,
	`frontEndVersion` VARCHAR(255) NOT NULL,
	`llvmVersion`     VARCHAR(255) NOT NULL,
	`gccVersion`      VARCHAR(255) NOT NULL,
	`updated`         DATETIME     NOT NULL,
	`versionHeader`   VARCHAR(255) NOT NULL,
	`helpStatus`      INT UNSIGNED NOT NULL,
	`helpOutput`      TEXT         NOT NULL,
	PRIMARY KEY (`type`, `compilerVersion`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;
";
 
immutable dbTroubleshootMsg =
`Please try the following:

1. Note that only MySQL/MariaDB is supported right now.

2. Make sure 'config.sdl' and your DB are set up correctly.
   See 'config.example.sdl' for details.

3. Make sure your DB user has the following permissions:
   SELECT, INSERT, UPDATE, DELETE

   Additionally, permissions for CREATE TABLE and DROP TABLE are needed for
   initial setup of the DB via --init-db (then they can be revoked if
   you wish).

4. Your DB user must use MySQL's new-style long password hash, not the
   very-old-style short password hash. (Just reset the DB user's password
   to be sure. It will use the new-style automatically.)

5. Run this program with the --init-db switch to create the needed DB tables
   (THIS WILL DESTROY ALL DATA!)
`;

void main()
{
	bool shouldInitDB = false;
	readOption("init-db", &shouldInitDB, "(Re-)Initialize the database and exit (WARNING! THIS WILL DESTROY ALL DATA!");

	// returns false if a help screen has been requested and displayed (--help)
	if (!finalizeCommandLineOptions())
		return;

	auto sdlConfig = parseFile("config.sdl");
	if("name"    in sdlConfig.tags) config.name    = sdlConfig.tags["name"   ][0].values[0].get!string;
	if("address" in sdlConfig.tags) config.address = sdlConfig.tags["address"][0].values.map!(a => a.get!string).array;
	if("port"    in sdlConfig.tags) config.port    = sdlConfig.tags["port"   ][0].values[0].get!int.to!ushort;
	if("pass-hash-sha256" in sdlConfig.tags) config.passHash = sdlConfig.tags["pass-hash-sha256"][0].values[0].get!string;

	config.dbHost      = sdlConfig.tags["db-host"      ][0].values[0].get!string;
	config.dbPort      = sdlConfig.tags["db-port"      ][0].values[0].get!int.to!ushort;
	config.dbName      = sdlConfig.tags["db-name"      ][0].values[0].get!string;
	config.dbUser      = sdlConfig.tags["db-user"      ][0].values[0].get!string;
	config.dbPass      = sdlConfig.tags["db-pass"      ][0].values[0].get!string;
	config.dbAdminUser = sdlConfig.tags["db-admin-user"][0].values[0].get!string;
	config.dbAdminPass = sdlConfig.tags["db-admin-pass"][0].values[0].get!string;
	config.dbAdminNewUserHost = sdlConfig.tags["db-admin-new-user-host"][0].values[0].get!string;

	if(shouldInitDB)
	{
		initDB();
		return;
	}

	// the router will match incoming HTTP requests to the proper routes
	auto router = new URLRouter();
	//router.get("/", &index);
	//router.get("/compiler", &compiler);
	router.post("/compiler", &postCompiler);
	// registers each method of WebInterface in the router
	//router.registerWebInterface(new WebInterface);
	// match incoming requests to files in the public/ folder
	router.get("*", serveStaticFiles("public/"));

	auto settings = new HTTPServerSettings;
	settings.port = config.port;
	settings.bindAddresses = config.address;
	listenHTTP(settings, router);
	logInfo(text("Please open http://", config.address[0], ":", config.port, "/ in your browser."));

	lowerPrivileges();
	auto dbConn = openDB();
	runEventLoop();
}

void initDB()
{
	scope(failure)
		logError("There was an error initializing the database.\n"~dbTroubleshootMsg);

	auto dbConn = openDBAdmin();
	auto db = Command(dbConn);

	void doSql(string rawSql)
	{
		auto processedSql = rawSql
			.replace("$DB_NAME", config.dbName)
			.replace("$DB_USER", config.dbUser)
			.replace("$DB_PASS", config.dbPass)
			.replace("$DB_ADMIN_NEW_USER_HOST", config.dbAdminNewUserHost);
			
		auto sqlInitStatements = processedSql.split(";");
		foreach(sql; sqlInitStatements)
		{
			sql = sql.strip();
			if(sql != "")
			{
				//logInfo("%s;", sql);
				db.sql = sql;
				ulong rowsAffected;
				db.execSQL(rowsAffected);
			}
		}
	}

	try
		doSql(dbInitUserSql);
	catch(MySQLException e)
	{
		logInfo("%s",
			"Unable to auto-init a limited user account. Skipping... "~
			"(Received error: "~e.msg~")"
		);
	}

	doSql(dbInitSchemaSql);

	logInfo("Initializing DB done.");
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

void postCompiler(HTTPServerRequest req, HTTPServerResponse res)
{
	if(!checkPassword(req, res))
		return;
	
	logInfo("Got valid POST");
	foreach(key, val; req.form)
	if(key != passFieldName)
		logInfo(text("  ", key, ": ", val));

	logInfo("Ok, adding new compiler\n");
	
	// Add compiler info to DB, if not already there.
	auto dbConn = openDB();
	{
		auto cmd = Command(dbConn);
		cmd.sql = "
			INSERT INTO `compilers` (
				`type`, `typeRaw`, `compilerVersion`, `frontEndVersion`, `llvmVersion`,
				`gccVersion`, `updated`, `versionHeader`, `helpStatus`, `helpOutput`
			) VALUES (
				?, ?, ?, ?, ?,
				?, ?, ?, ?, ?
			)
		";
		cmd.prepare();

		string getForm(string name)
		{
			if(auto pVal = name in req.form)
				return *pVal;
			
			auto msg = "Missing form value: "~name;
			logError(msg);
			throw new Exception(msg);
		}

		auto DC_TYPE              = getForm("DC_TYPE");
		auto DC_TYPE_RAW          = getForm("DC_TYPE_RAW");
		auto DC_COMPILER_VERSION  = getForm("DC_COMPILER_VERSION");
		auto DC_FRONT_END_VERSION = getForm("DC_FRONT_END_VERSION");
		auto DC_LLVM_VERSION      = getForm("DC_LLVM_VERSION");
		auto DC_GCC_VERSION       = getForm("DC_GCC_VERSION");
		auto DC_VERSION_HEADER    = getForm("DC_VERSION_HEADER");
		auto DC_HELP_STATUS       = getForm("DC_HELP_STATUS").to!ubyte;
		auto DC_HELP_OUTPUT       = getForm("DC_HELP_OUTPUT");
		auto updated = cast(DateTime) Clock.currTime;
		cmd.bindParameter(DC_TYPE,              0);
		cmd.bindParameter(DC_TYPE_RAW,          1);
		cmd.bindParameter(DC_COMPILER_VERSION,  2);
		cmd.bindParameter(DC_FRONT_END_VERSION, 3);
		cmd.bindParameter(DC_LLVM_VERSION,      4);
		cmd.bindParameter(DC_GCC_VERSION,       5);
		cmd.bindParameter(updated,              6);
		cmd.bindParameter(DC_VERSION_HEADER,    7);
		cmd.bindParameter(DC_HELP_STATUS,       8);
		cmd.bindParameter(DC_HELP_OUTPUT,       9);

		ulong rowsAffected;
		try
			cmd.execPrepared(rowsAffected);
		catch(MySQLException e)
		{
			if(e.msg.canFind("Duplicate entry"))
			{
				res.writeBody("Compiler already in DB. Doing nothing.\n");
				return;
			}
			
			throw e;
		}
	}

	// Pre-generate HTML page
	auto context = new TempleContext();
	context.name = config.name;
	auto cmd = Command(dbConn);
	cmd.sql = "
		SELECT
			`type`, `typeRaw`, `compilerVersion`, `frontEndVersion`, `llvmVersion`,
			`gccVersion`, `updated`, `versionHeader`, `helpStatus`, `helpOutput`
		FROM `compilers`
		ORDER BY `typeRaw` ASC, `type` ASC, `compilerVersion` ASC;
	";
	auto rows = cmd.execSQLSequence();
	DCompiler[] dcompilers;
	foreach(row; rows)
	{
		DCompiler dc;
		dc.type            = row[0].get!string();
		dc.typeRaw         = row[1].get!string();
		dc.compilerVersion = row[2].get!string();
		dc.frontEndVersion = row[3].get!string();
		dcompilers ~= dc;
	}
	context.dcompilers = dcompilers;
	
	auto pageTemplate = compile_temple_file!"index.html";
	auto html = pageTemplate.toString(context);

	// Store HTML page in unique temp file (for atomicity)
	static import std.ascii;
	auto chars = std.ascii.digits ~ std.ascii.letters;
	string getTempFilename()
	{
		import std.random;

		auto buf = appender!string();
		foreach(i; 0..32)
			buf.put(chars.randomSample(1, chars.length));
		return ".tmp_" ~ buf.data;
	}

	auto publicDir = buildNormalizedPath(thisExePath().baseName(), "..", "public");
	auto targetHtmlPath = buildPath(publicDir, "index.html");
	string tmpHtmlPath;
	bool ok = false;
	foreach(i; 0..256)
	{
		tmpHtmlPath = buildPath(publicDir, getTempFilename());
		File file;
		try
			file = File(tmpHtmlPath, "wx");
		catch(Exception e)
			continue;

		file.rawWrite(html);
		ok = true;
		break;
	}
	if(!ok)
		throw new Exception("Couldn't create unique temp file.");

	// Atomic move temp file to target file
	rename(tmpHtmlPath, targetHtmlPath);

//	res.contentType = "text/html; charset=UTF-8";
	res.writeBody("Ok, added new compiler\n");
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

LockedConnection!Connection openDB()
{
	return openDBFor(config.dbUser, config.dbPass, config.dbName);
}

LockedConnection!Connection openDBAdmin()
{
	return openDBFor(config.dbAdminUser, config.dbAdminPass, null);
}

private MysqlDB dbPool;
private LockedConnection!Connection openDBFor(string dbUser, string dbPass, string dbName)
{
	if(!dbPool)
	{
		dbPool = new MysqlDB(
			config.dbHost, dbUser, dbPass,
			dbName, config.dbPort
		);
	}

	auto dbConn = dbPool.lockConnection();

	if(dbConn.closed)
		dbConn.reconnect();
	
	return dbConn;
}
