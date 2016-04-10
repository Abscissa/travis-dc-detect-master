module dcompiler;

struct DCompiler
{
	string type;
	string typeRaw;

	string versionHeader;
	string compilerVersion;
	string frontEndVersion;
	string llvmVersion;
	string gccVersion;

	string fullCompilerOutput;
	int fullCompilerStatus;
}
