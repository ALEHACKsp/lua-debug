#include <debugger/client/attach.h>
#include <Windows.h>
#include <debugger/client/run.h>
#include <debugger/io/base.h>
#include <debugger/io/helper.h>
#include <debugger/client/stdinput.h>
#include <base/util/format.h>
#include <base/path/self.h>
#include <functional>

static void sleep() {
	std::this_thread::sleep_for(std::chrono::milliseconds(10));
}

void request_runInTerminal(vscode::io::base* io, std::function<void(vscode::wprotocol&)> args)
{
	vscode::wprotocol res;
	for (auto _ : res.Object())
	{
		res("type").String("request");
		//res("seq").Int64(seq++);
		res("command").String("runInTerminal");
		for (auto _ : res("arguments").Object())
		{
			args(res);
		}
	}
	vscode::io_output(io, res);
}

int run_terminal_then_attach(stdinput& io, vscode::rprotocol& init, vscode::rprotocol& req)
{
	auto& args = req["arguments"];
	bool sourceCodingUtf8 = false;
	std::string sourceCoding = "ansi";
	if (args.HasMember("sourceCoding") && args["sourceCoding"].IsString()) {
		sourceCodingUtf8 = "utf8" == args["sourceCoding"].Get<std::string>();
	}

	request_runInTerminal(&io, [&](vscode::wprotocol& res) {
		res("kind").String(args["console"] == "integratedTerminal" ? "integrated" : "external");
		res("title").String("Lua Debug");
		if (args.HasMember("cwd") && args["cwd"].IsString()) {
			res("cwd").String(args["cwd"]);
		}
		if (args.HasMember("env") && args["env"].IsObject()) {
			for (auto _ : res("env").Object()) {
				for (auto& v : args["env"].GetObject()) {
					if (v.name.IsString()) {
						if (v.value.IsString()) {
							res(v.name).String(v.value);
						}
						else if (v.value.IsNull()) {
							res(v.name).Null();
						}
					}
				}
			}
		}

		for (auto _ : res("args").Array()) {
			res.String((base::path::self().remove_filename() / "lua.exe").string());

			res.String("-e");
			res.String(R"(local dbg = require [[debugger]] dbg:listen([[127.0.0.1:4278]]) dbg:start())");

			if (args.HasMember("path") && args["path"].IsString()) {
				std::string path = sourceCodingUtf8 ? args["path"].Get<std::string>() : base::u2a(args["path"]);
				res.String("-e");
				res.String(base::format("package.path=[[%s]]", path));
			}
			if (args.HasMember("cpath") && args["cpath"].IsString()) {
				std::string path = sourceCodingUtf8 ? args["cpath"].Get<std::string>() : base::u2a(args["cpath"]);
				res.String("-e");
				res.String(base::format("package.cpath=[[%s]]", path));
			}

			if (args.HasMember("arg0")) {
				if (args["arg0"].IsString()) {
					auto& v = args["arg0"];
					res.String(v);
				}
				else if (args["arg0"].IsArray()) {
					for (auto& v : args["arg0"].GetArray()) {
						if (v.IsString()) {
							res.String(v);
						}
					}
				}
			}

			std::string program = ".lua";
			if (args.HasMember("program") && args["program"].IsString()) {
				program = sourceCodingUtf8 ? args["program"].Get<std::string>() : base::u2a(args["program"]);
			}
			res.String(program);

			if (args.HasMember("arg") && args["arg"].IsArray()) {
				for (auto& v : args["arg"].GetArray()) {
					if (v.IsString()) {
						res.String(v);
					}
				}
			}
		}
	});

	attach attach(io);
	std::string ip = "127.0.0.1";
	uint16_t port = 4278;
	attach.connect(net::endpoint(ip, port));
	attach.send(init);
	attach.send(req);
	for (;; sleep()) {
		attach.update();
	}
	return 0;
}
