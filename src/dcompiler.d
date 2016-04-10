module dcompiler;

import std.datetime;

struct DCompiler
{
	string type;
	string typeRaw;

	string versionHeader;
	string compilerVersion;
	string frontEndVersion;
	string llvmVersion;
	string gccVersion;

	string helpOutput;
	int helpStatus;

	DateTime updated;
}
