import std.conv;
import std.datetime;
import std.file;
import std.path;
import std.stdio;

import vibe.vibe;
import vibe.core.connectionpool;
import vibe.core.log;

import mysql.db;
import temple;
import sdlang;

import dcompiler;

alias write = std.stdio.write;

struct Config
{
	string[] address = ["127.0.0.1", "::1"];
	ushort port = 8080;
	string urlPrefix = "/";
	string travisApiToken;
	string travisRepoUser;
	string travisRepoName;
	string travisRepoBranch;
	string logFile;
	string passHash; // SHA256

	string dbHost;
	ushort dbPort;
	string dbName;
	string dbUser;
	string dbPass;
	string dbAdminUser;
	string dbAdminPass;
	string dbAdminNewUserHost;

	string thisProjectPath;
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
	`helpStatus`      INT          NOT NULL,
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

	config.thisProjectPath = buildPath(thisExePath().dirName(), "..");
	auto sdlConfigPath = buildPath(config.thisProjectPath, "config.sdl");
	auto sdlConfig = parseFile(sdlConfigPath);
	if("address"            in sdlConfig.tags) config.address          = sdlConfig.tags["address"           ][0].values.map!(a => a.get!string).array;
	if("port"               in sdlConfig.tags) config.port             = sdlConfig.tags["port"              ][0].values[0].get!int.to!ushort;
	if("url-prefix"         in sdlConfig.tags) config.urlPrefix        = sdlConfig.tags["url-prefix"        ][0].values[0].get!string;
	if("travis-api-token"   in sdlConfig.tags) config.travisApiToken   = sdlConfig.tags["travis-api-token"  ][0].values[0].get!string;
	if("travis-repo-user"   in sdlConfig.tags) config.travisRepoUser   = sdlConfig.tags["travis-repo-user"  ][0].values[0].get!string;
	if("travis-repo-name"   in sdlConfig.tags) config.travisRepoName   = sdlConfig.tags["travis-repo-name"  ][0].values[0].get!string;
	if("travis-repo-branch" in sdlConfig.tags) config.travisRepoBranch = sdlConfig.tags["travis-repo-branch"][0].values[0].get!string;
	if("log-file"           in sdlConfig.tags) config.logFile          = sdlConfig.tags["log-file"          ][0].values[0].get!string;
	if("pass-hash-sha256"   in sdlConfig.tags) config.passHash         = sdlConfig.tags["pass-hash-sha256"  ][0].values[0].get!string;

	if("db-host" in sdlConfig.tags) config.dbHost = sdlConfig.tags["db-host"][0].values[0].get!string;
	if("db-port" in sdlConfig.tags) config.dbPort = sdlConfig.tags["db-port"][0].values[0].get!int.to!ushort;
	if("db-user" in sdlConfig.tags) config.dbUser = sdlConfig.tags["db-user"][0].values[0].get!string;
	if("db-name" in sdlConfig.tags) config.dbName = sdlConfig.tags["db-name"][0].values[0].get!string;
	if("db-pass" in sdlConfig.tags) config.dbPass = sdlConfig.tags["db-pass"][0].values[0].get!string;
	if("db-admin-user"          in sdlConfig.tags) config.dbAdminUser = sdlConfig.tags["db-admin-user"][0].values[0].get!string;
	if("db-admin-pass"          in sdlConfig.tags) config.dbAdminPass = sdlConfig.tags["db-admin-pass"][0].values[0].get!string;
	if("db-admin-new-user-host" in sdlConfig.tags) config.dbAdminNewUserHost = sdlConfig.tags["db-admin-new-user-host"][0].values[0].get!string;

	if(!config.urlPrefix.startsWith("/"))
		config.urlPrefix = "/" ~ config.urlPrefix;

	if(!config.urlPrefix.endsWith("/"))
		config.urlPrefix = config.urlPrefix ~ "/";

	if(shouldInitDB)
	{
		initDB();
		return;
	}

	if(config.logFile)
		setLogFile(config.logFile, LogLevel.warn);

	// the router will match incoming HTTP requests to the proper routes
	auto router = new URLRouter();
	//router.get(config.urlPrefix~"", &index);
	//router.get(config.urlPrefix~"compiler", &compiler);
	router.post(config.urlPrefix~"compiler", &postCompiler);

	auto publicPath = buildPath(config.thisProjectPath, "public/");
	auto fileServerSettings = new HTTPFileServerSettings();
	fileServerSettings.serverPathPrefix = config.urlPrefix;
	router.get("*", serveStaticFiles(publicPath, fileServerSettings));

	auto settings = new HTTPServerSettings;
	settings.port = config.port;
	settings.bindAddresses = config.address;
	settings.accessLogToConsole = true;
	settings.errorPageHandler = (req,res,err) => onError(req,res,err);
	listenHTTP(settings, router);
	logInfo(text("Please open http://", config.address[0], ":", config.port, "/ in your browser."));

	logInfo("Triggering initial travis rebuild of travis-dc-detect-slave");
	triggerTravisRebuild();
	setTimer(24.hours, toDelegate(&triggerTravisRebuild), true);

	lowerPrivileges();
	auto dbConn = openDB();
	regenerateHTMLPage();
	runEventLoop();
}

void onError(HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo errInfo)
{
	res.writeBody(text(res.statusCode, " - ", res.statusPhrase, "\n"));
	logError("%s", text("HTTP ", errInfo.code, ": ", errInfo.debugMessage));
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
	
	//logInfo("Got valid POST");
	//foreach(key, val; req.form)
	//if(key != passFieldName)
	//	logInfo(text("  ", key, ": ", val));

	logInfo("Ok, adding new compiler\n");
	
	// Add compiler info to DB, if not already there.
	auto dbConn = openDB();
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
	auto DC_HELP_STATUS       = getForm("DC_HELP_STATUS").to!int;
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

	// Regenerate HTML page
	regenerateHTMLPage();

//	res.contentType = "text/html; charset=UTF-8";
	res.writeBody("Ok, added new compiler\n");
}

void regenerateHTMLPage()
{
	auto context = new TempleContext();

	auto dbConn = openDB();
	auto cmd = Command(dbConn);
	cmd.sql = "
		SELECT
			`type`, `typeRaw`, `compilerVersion`, `frontEndVersion`, `llvmVersion`,
			`gccVersion`, `updated`, `versionHeader`, `helpStatus`, `helpOutput`
		FROM `compilers`
		ORDER BY `typeRaw` ASC, `type` ASC, `compilerVersion` DESC;
	";
	auto rows = cmd.execSQLSequence();

	string cleanupVersionString(string ver)
	{
		if(ver == "unknown")
			return ver;

		else if(ver == "none")
			return "(none)";

		return "v"~ver;
	}

	string classOfString(string str)
	{
		if(str == "unknown" || str == "none")
			return str;

		return "normal";
	}

	string classOfExitStatus(int status)
	{
		return status == 0? "normal" : "error";
	}

	// The name travis uses for a particular compiler type & version
	string travisCompilerName(string type, string ver)
	{
		if(type == "ldc2")
			type = "ldc";

		if(type == "unknown")
			return type;
		else
			return type ~ "-" ~ ver;
	}

	DCompiler[] dcompilers;
	foreach(row; rows)
	{
		auto type            = row[0].get!string();
		auto typeRaw         = row[1].get!string();
		auto compilerVersion = row[2].get!string();
		auto frontEndVersion = row[3].get!string();
		auto llvmVersion     = row[4].get!string();
		auto gccVersion      = row[5].get!string();
		auto updated         = row[6].get!DateTime();
		auto versionHeader   = row[7].get!string();
		auto helpStatus      = row[8].get!int();
		auto name = travisCompilerName(type, compilerVersion);

		DCompiler dc;
		dc.name            = name;
		dc.type            = type==typeRaw? type : type~" ("~typeRaw~")";
		dc.compilerVersion = cleanupVersionString( compilerVersion );
		dc.frontEndVersion = cleanupVersionString( frontEndVersion );
		dc.llvmVersion     = cleanupVersionString( llvmVersion );
		dc.gccVersion      = cleanupVersionString( gccVersion );
		dc.updated         = updated;
		dc.versionHeader   = versionHeader;
		dc.helpStatus      = helpStatus;

		dc.className            = classOfString(name);
		dc.classType            = classOfString(type);
		dc.classCompilerVersion = classOfString(compilerVersion);
		dc.classFrontEndVersion = classOfString(frontEndVersion);
		dc.classLlvmVersion     = classOfString(llvmVersion);
		dc.classGccVersion      = classOfString(gccVersion);
		dc.classVersionHeader   = classOfString(versionHeader);
		dc.classHelpStatus      = classOfExitStatus(helpStatus);
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

	auto publicDir = buildNormalizedPath(config.thisProjectPath, "public");
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
} 

// Does this: https://docs.travis-ci.com/user/triggering-builds
void triggerTravisRebuild()
{
	import std.net.curl;
 	
	auto postBody = `{
		"request": {
		"branch":"`~config.travisRepoBranch~`"
		}}`;

	auto http = HTTP("https://api.travis-ci.org/repo/"~config.travisRepoUser~"%2F"~config.travisRepoName~"/requests");
	http.setPostData(postBody, "application/json");
	http.addRequestHeader("Accept", "application/json");
	http.addRequestHeader("Travis-API-Version", "3");
	http.addRequestHeader("Authorization", "token "~config.travisApiToken);
	http.perform();
	writeln();
	
	if(http.statusLine.code >= 400)
		logError("%s", text("Couldn't trigger travis rebuild: HTTP status ", http.statusLine.code));
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
