#!/usr/bin/env ruby

require "pathname"
require "optparse"
require "shellwords"
require "set"

# platform: iphone, iphone-simulator
# arch: armv7, arm64, i386, x86_64
# configuration: Debug, Release

class CommonGypi
	attr_reader :file
	attr_reader :lines
	def initialize(file)
		@file = file
		@lines = file.readlines
	end
	def save
		text = lines.join("")
		file.binwrite(text)
	end
	def set_enable_bitcode(value)
		value_str = value ? "YES" : "NO"
		regex = /'ENABLE_BITCODE': '([\w]*)'/
		for line in lines
			m = regex.match(line)
			if ! m
				next
			end
			line[m.begin(1)...m.end(1)] = value_str
		end
	end
end

class App
	attr_reader :script_dir
	attr_reader :webrtc_dir

	attr_reader :platform
	attr_reader :arch
	attr_reader :configuration

	attr_reader :bitcode_enabled
	attr_reader :verbose

	def xcode_platform
		case platform
		when "iphone"
			return "iphoneos"
		when "iphone-simulator"
			return "iphonesimulator"
		else
			raise "invalid platform: #{platform}"
		end
	end
	def xcode_arch
		arch
	end
	def gyp_dir
		webrtc_dir + "src/tools/gyp"
	end
	def main
		@verbose = false
		@webrtc_dir = nil
		@bitcode_enabled = true

		opt_parser = OptionParser.new
		opt_parser.on("-v", "--verbose") {
			@verbose = true
		}
		opt_parser.on("--webrtc DIR") {|v|
			@webrtc_dir = Pathname(v).expand_path
		}
		opt_parser.on("--disable-bitcode") {
			@bitcode_enabled = false
		}
		opt_parser.parse!(ARGV)

		@script_dir = Pathname(__FILE__).parent.expand_path
		@configuration = "Release"

		subcmd = "build"
		if 0 < ARGV.length
			subcmd = ARGV[0]
		end

		case subcmd
		when "build"
			build
		when "clean"
			clean
		else
			raise "undefined sub command: #{subcmd}"
		end
	end
	def make_output_dir
		dir = output_dir
		dir.mkpath
		(dir + ".keep").binwrite("")
	end
	def set_target(platform, arch)
		@platform = platform
		@arch = arch
	end
	def output_dir
		script_dir + "out"
	end
	def project_dir
		output_dir + "project-ninja"
	end
	def project_target_dir
		project_dir + "#{platform}-#{arch}"
	end
	def project_configured_target_dir
		project_target_dir + "#{configuration}-#{xcode_platform}"
	end
	def lib_dir
		output_dir + "lib"
	end
	def include_dir
		output_dir + "include"
	end
	def build
		if webrtc_dir == nil
			raise "webrtc is nil"
		end

		if bitcode_enabled
			cmd = [(script_dir + "patch-gyp.rb").to_s, 
				gyp_dir.to_s].shelljoin
			exec(cmd)
		end

		project_source = CommonGypi.new(webrtc_dir + "src/build/common.gypi")
		project_source.set_enable_bitcode(bitcode_enabled)
		project_source.save
		puts "update project source: #{project_source.file.to_s}"

		make_output_dir

		targets = [
			["iphone", "armv7"],
			["iphone", "arm64"],
			["iphone-simulator", "i386"],
			["iphone-simulator", "x86_64"]
		]

		for target in targets
			set_target(*target)
			build_target
		end

		all_lib_names = Set.new
		for target in targets
			set_target(*target)
			lib_names = project_configured_target_dir.children
				.select {|x| x.extname == ".a" }
				.map{|x| x.basename.to_s }
			for lib_name in lib_names
				all_lib_names << lib_name
			end
		end

		lib_dir.mkpath
		for lib_name in all_lib_names
			fat_lib = lib_dir + lib_name
			if ! fat_lib.exist?
				thin_libs = targets
					.map {|target|
						set_target(*target)

						thin_lib = project_configured_target_dir + lib_name
						if ! thin_lib.exist?
							puts "make dummy #{lib_name} for (#{platform}, #{target})"
							make_dummy_static_lib(thin_lib)
						end
						thin_lib
					}
				make_fat_lib(thin_libs, lib_dir + lib_name)
			end
		end

		Dir.chdir((webrtc_dir + "src").to_s)
		if ! include_dir.exist?
			puts "copy headers"	
			for file_str in Dir.glob(["webrtc/**/*", "talk/**/*"]).each
				file = Pathname(file_str)
				dest_file = include_dir + file
				if file.directory?
					dest_file.mkpath
				elsif file.extname == ".h"
					FileUtils.copy(file, dest_file)
				end
			end
		end
	end
	def build_target
		output_dir = project_target_dir
		output_dir.parent.mkpath

		if ! output_dir.exist?
			puts "generate project (#{platform}, #{arch})"

			gyp_defines = ["OS=ios", "clang_xcode=1"]

			if platform == "iphone" && arch == "armv7"
				gyp_defines << "target_arch=arm"
				gyp_defines << "target_subarch=arm32"
				gyp_defines << "arm_version=7"
			elsif platform == "iphone" && arch == "arm64"
				gyp_defines << "target_arch=arm64"
				gyp_defines << "target_subarch=arm64"
			elsif platform == "iphone-simulator" && arch == "i386"
				gyp_defines << "target_arch=ia32"
			elsif platform == "iphone-simulator" && arch == "x86_64"
				gyp_defines << "target_arch=x64"
			else
				raise "unsupported target: platform=#{platform}, arch=#{arch}"
			end

			ENV["GYP_DEFINES"] = gyp_defines.join(" ")
			ENV["GYP_CROSSCOMPILE"] = "1"
			ENV["GYP_GENERATOR_FLAGS"] = "output_dir=\"#{output_dir.to_s}\""
			ENV["GYP_GENERATORS"] = "ninja"

			Dir.chdir(webrtc_dir + "src")
			exec(["webrtc/build/gyp_webrtc"].shelljoin)
		end
		if ! (project_configured_target_dir + "AppRTCDemo.app").exist?
			puts "build target (#{platform}, #{arch}, #{configuration})"

			cmd = ["ninja", "-C", project_configured_target_dir.to_s, "AppRTCDemo"]
			exec(cmd.shelljoin)
		end
	end
	def make_fat_lib(thin_libs, fat_lib)
		puts "make fat lib: #{fat_lib.basename.to_s}"
		cmd = ["lipo", "-create"] +
			thin_libs.map{|x| x.to_s } +
			["-output", fat_lib.to_s]
		exec(cmd.shelljoin)
	end
	def clean
		if output_dir.exist?
			output_dir.rmtree
		end
		make_output_dir
	end
	def xcode_tool_path(name)
		exec_capture(["xcrun", "-sdk", xcode_platform, "-f", name].shelljoin).strip
	end
	def compile_static_lib(sources, lib)
		cc = xcode_tool_path("clang")
		sdk = exec_capture(["xcrun", "-sdk", xcode_platform, "--show-sdk-path"].shelljoin).strip

		objs = sources
			.map{|source| 
				obj = source.sub_ext(".o")
				cmd = [cc, 
					"-isysroot", sdk, 
					"-arch", xcode_arch]
				if platform == "iphone"
					cmd << "-miphoneos-version-min=7.0"
				elsif platform == "iphone-simulator"
					cmd << "-mios-simulator-version-min=7.0"
				end
					
				if bitcode_enabled
					cmd << "-fembed-bitcode"
				end
				cmd += [
					"-c", source.to_s,
					"-o", obj.to_s]
				exec(cmd.shelljoin)
				obj
			 }

		libtool = xcode_tool_path("libtool")

		cmd = [libtool, "-static" ] + 
			objs.map{|x| x.to_s } +
			["-o", lib.to_s]
		exec(cmd.shelljoin)
	end
	def make_dummy_static_lib(lib)
		name = lib.basename(lib.extname)
		symbol = "#{name}_dummy_symbol"
		code = "int #{symbol}() { return 0; }"
		source_path = lib.sub_ext(".c")
		source_path.binwrite(code)
		compile_static_lib([source_path], lib)
	end
	def exec(command)
		ret = system(command)
		if ! ret
			raise "exec failed: status=#{$?}, command=#{command}"
		end
	end
	def exec_capture(command)
		`#{command}`
	end
end

app = App.new
app.main()