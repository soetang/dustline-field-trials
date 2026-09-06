// Compiled only by engine-backbuffer-check.js after injecting actual pinned
// original and patched definitions. This GL mock covers attachment lifecycle,
// not the complete GL specification, driver synchronization, or performance.
#include <algorithm>
#include <cstdint>
#include <functional>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

using GLuint = unsigned int;
using GLenum = unsigned int;
constexpr GLenum GL_FRAMEBUFFER = 0x8d40, GL_FRAMEBUFFER_COMPLETE = 0x8cd5;
constexpr GLenum GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT = 0x8cd6, GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT = 0x8cd7;
constexpr GLenum GL_TEXTURE_2D = 0x0de1, GL_TEXTURE_2D_ARRAY = 0x8c1a;
constexpr GLenum GL_DEPTH24_STENCIL8 = 0x88f0, GL_DEPTH_STENCIL = 0x84f9, GL_UNSIGNED_INT_24_8 = 0x84fa;
constexpr GLenum GL_RGBA8 = 0x8058, GL_RGBA = 0x1908, GL_UNSIGNED_BYTE = 0x1401;
constexpr GLenum GL_COLOR_ATTACHMENT0 = 0x8ce0, GL_DEPTH_STENCIL_ATTACHMENT = 0x821a;
constexpr GLenum GL_TEXTURE_MAG_FILTER = 0x2800, GL_TEXTURE_MIN_FILTER = 0x2801;
constexpr GLenum GL_TEXTURE_WRAP_S = 0x2802, GL_TEXTURE_WRAP_T = 0x2803;
constexpr GLenum GL_NEAREST = 0x2600, GL_CLAMP_TO_EDGE = 0x812f;

void require(bool value, const std::string &message) {
	if (!value) throw std::runtime_error(message);
}

struct Texture { int width = 0, height = 0, layers = 0; };
struct Framebuffer { GLuint color = 0, depth = 0; };
struct MockGL {
	GLuint next_fbo = 1, next_texture = 1, bound_fbo = 0, bound_texture = 0;
	int texture_generations = 0, fail_texture_generation = -1;
	bool fail_fbo = false, fail_image = false, lost = false;
	int forced_status = -1, checks = 0, warnings = 0;
	std::map<GLuint, Texture> textures;
	std::map<GLuint, Framebuffer> framebuffers;
	std::map<GLuint, uint32_t> accounted;
	std::vector<std::string> calls;
	void record(const std::string &name, std::initializer_list<int64_t> values = {}, const std::string &detail = "") {
		std::string line = name;
		for (auto value : values) line += ":" + std::to_string(value);
		calls.push_back(line + (detail.empty() ? "" : ":" + detail));
	}
};
MockGL *active = nullptr;

void glGenFramebuffers(int n, GLuint *id) {
	require(n == 1, "Unexpected framebuffer generation count");
	*id = active->fail_fbo || active->lost ? 0 : active->next_fbo++;
	active->fail_fbo = false;
	if (*id) active->framebuffers[*id] = {};
	active->record("gen_fbo", {*id});
}
void glBindFramebuffer(GLenum target, GLuint id) {
	active->record("bind_fbo", {target, id});
	if (!active->lost) active->bound_fbo = id;
}
void glDeleteFramebuffers(int n, const GLuint *id) {
	require(n == 1, "Unexpected framebuffer deletion count");
	active->record("delete_fbo", {*id});
	if (!active->lost) {
		active->framebuffers.erase(*id);
		if (active->bound_fbo == *id) active->bound_fbo = 0;
	}
}
void glGenTextures(int n, GLuint *id) {
	require(n == 1, "Unexpected texture generation count");
	active->texture_generations++;
	*id = active->texture_generations == active->fail_texture_generation || active->lost ? 0 : active->next_texture++;
	if (*id) active->textures[*id] = {};
	active->record("gen_texture", {*id});
}
void glBindTexture(GLenum target, GLuint id) {
	active->record("bind_texture", {target, id});
	if (!active->lost) active->bound_texture = id;
}
void image_storage(int width, int height, int layers) {
	if (active->lost || !active->bound_texture) return;
	if (active->fail_image) { active->fail_image = false; return; }
	active->textures.at(active->bound_texture) = {width, height, layers};
}
void glTexImage2D(GLenum target, int level, GLenum format, int width, int height, int border, GLenum external_format, GLenum type, const void *data) {
	require(data == nullptr, "Backbuffer must allocate empty storage");
	active->record("image2d", {target, level, format, width, height, border, external_format, type});
	image_storage(width, height, 1);
}
void glTexImage3D(GLenum target, int level, GLenum format, int width, int height, int layers, int border, GLenum external_format, GLenum type, const void *data) {
	require(data == nullptr, "Backbuffer must allocate empty storage");
	active->record("image3d", {target, level, format, width, height, layers, border, external_format, type});
	image_storage(width, height, layers);
}
void glTexParameteri(GLenum target, GLenum parameter, int value) {
	active->record("parameter", {target, parameter, value});
}
void attach(GLenum attachment, GLuint texture) {
	// Attaching to the real default framebuffer is invalid. A complete default
	// FBO may nevertheless make the subsequent status check appear successful.
	if (active->lost || !active->bound_fbo) return;
	auto &fbo = active->framebuffers.at(active->bound_fbo);
	if (attachment == GL_COLOR_ATTACHMENT0) fbo.color = texture;
	else { require(attachment == GL_DEPTH_STENCIL_ATTACHMENT, "Unexpected attachment"); fbo.depth = texture; }
}
void glFramebufferTexture2D(GLenum target, GLenum attachment, GLenum texture_target, GLuint texture, int level) {
	active->record("attach2d", {target, attachment, texture_target, texture, level});
	attach(attachment, texture);
}
void glFramebufferTextureMultiviewOVR(GLenum target, GLenum attachment, GLuint texture, int level, int base_view, unsigned views) {
	active->record("attach_multiview", {target, attachment, texture, level, base_view, views});
	attach(attachment, texture);
}
GLenum glCheckFramebufferStatus(GLenum target) {
	GLenum status = GL_FRAMEBUFFER_COMPLETE;
	if (active->lost) status = 0;
	else if (active->forced_status >= 0) { status = active->forced_status; active->forced_status = -1; }
	else if (active->bound_fbo) {
		const auto &fbo = active->framebuffers.at(active->bound_fbo);
		if (!fbo.color && !fbo.depth) status = GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT;
		Texture previous;
		for (GLuint texture : {fbo.color, fbo.depth}) {
			if (!texture) continue; // A color-only or depth-only FBO can be complete.
			const auto found = active->textures.find(texture);
			if (found == active->textures.end() || found->second.width <= 0 || found->second.height <= 0) {
				status = GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT; break;
			}
			const auto &storage = found->second;
			if (previous.width && (storage.width != previous.width || storage.height != previous.height || storage.layers != previous.layers))
				status = GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT;
			previous = storage;
		}
	}
	active->checks++;
	active->record("check", {target, status});
	return status;
}

namespace GLES3 {
struct Config {
	bool multiview_supported = true;
	static Config *get_singleton() { static Config instance; return &instance; }
};
struct TextureStorage {
	static constexpr GLuint system_fbo = 0;
	static TextureStorage *get_singleton() { static TextureStorage instance; return &instance; }
	std::string get_framebuffer_error(GLenum status) { return std::to_string(status); }
};
struct Utilities {
	static Utilities *get_singleton() { static Utilities instance; return &instance; }
	void texture_allocated_data(GLuint texture, uint32_t size, const std::string &name) {
		active->record("account_texture", {texture, size}, name);
		active->accounted[texture] = size; // Deliberately preserves upstream ID-0 accounting.
	}
	void texture_free_data(GLuint texture) {
		require(active->accounted.count(texture) == 1, "Free of unaccounted texture");
		active->record("free_texture", {texture});
		active->accounted.erase(texture);
		if (!active->lost) active->textures.erase(texture);
	}
};
}
void warn_print(const std::string &message) { active->warnings++; active->record("warn", {}, message); }
#define WARN_PRINT(message) warn_print(message)

struct Buffers {
	struct Size { int x = 640, y = 360; } internal_size;
	struct IDs { GLuint color = 0, depth = 0, fbo = 0; } backbuffer3d;
	uint32_t view_count = 1, color_format_size = 4;
	GLuint color_internal_format = GL_RGBA8, color_format = GL_RGBA, color_type = GL_UNSIGNED_BYTE;
	virtual void check_backbuffer(bool, bool) = 0;
	virtual void _clear_back_buffers() = 0;
	virtual ~Buffers() = default;
	std::string ids() const {
		return std::to_string(backbuffer3d.fbo) + ":" + std::to_string(backbuffer3d.color) + ":" + std::to_string(backbuffer3d.depth);
	}
};
struct OriginalBuffers : Buffers { void check_backbuffer(bool, bool) override; void _clear_back_buffers() override; };
struct PatchedBuffers : Buffers { void check_backbuffer(bool, bool) override; void _clear_back_buffers() override; };

// @EXTRACTED_FUNCTIONS@

struct Trial {
	Buffers &buffers;
	MockGL &gl;
	bool patched;
	std::vector<std::string> snapshots;
	void call(const std::string &label, bool color, bool depth, int patched_checks) {
		const int before = gl.checks;
		buffers.check_backbuffer(color, depth);
		require(gl.checks - before == (patched ? patched_checks : 1), label + ": unexpected completeness-check count");
		require(gl.bound_fbo == GLES3::TextureStorage::system_fbo && gl.bound_texture == 0,
				label + ": framebuffer/texture bindings not restored");
		snapshots.push_back(label + ":" + buffers.ids() + ":warnings=" + std::to_string(gl.warnings));
	}
	void clear() {
		buffers._clear_back_buffers();
		require(buffers.ids() == "0:0:0", "Actual clear body must zero every ID");
	}
};
struct Result { std::vector<std::string> calls, snapshots; std::string ids; int checks = 0, warnings = 0; };
template<class T> Result execute(bool patched, const std::function<void(Trial &)> &scenario) {
	MockGL gl;
	active = &gl;
	T buffers;
	Trial trial{buffers, gl, patched, {}};
	scenario(trial);
	return {gl.calls, trial.snapshots, buffers.ids(), gl.checks, gl.warnings};
}
std::vector<std::string> non_checks(const Result &result) {
	std::vector<std::string> calls;
	for (const auto &call : result.calls) if (call.rfind("check:", 0) != 0) calls.push_back(call);
	return calls;
}
int comparisons = 0;
void compare(const std::string &name, const std::function<void(Trial &)> &scenario) {
	const auto original = execute<OriginalBuffers>(false, scenario);
	const auto patched = execute<PatchedBuffers>(true, scenario);
	require(original.snapshots == patched.snapshots, name + ": IDs/warnings differ from baseline");
	require(non_checks(original) == non_checks(patched), name + ": allocation/attachment/cleanup/bind calls differ from baseline");
	std::cout << "PASS " << name << " (checks " << original.checks << " -> " << patched.checks << ")\n";
	comparisons++;
}

int main() {
	try {
		compare("depth, unchanged, add color, unchanged", [](Trial &t) {
			t.call("depth", false, true, 1); t.call("same depth", false, true, 0);
			t.call("add color", true, true, 1); t.call("same both", true, true, 0);
		});
		compare("color first, then depth and requirement subsets", [](Trial &t) {
			t.call("color", true, false, 1); t.call("same color", true, false, 0);
			t.call("add depth", true, true, 1); t.call("same both", true, true, 0);
			t.call("only depth needed", false, true, 0); t.call("both needed again", true, true, 0);
		});
		compare("clear, resize, format and multiview reconfiguration", [](Trial &t) {
			t.call("initial", true, true, 1); t.clear();
			t.buffers.internal_size = {960, 540};
			t.call("resized", true, true, 1); t.call("same size", true, true, 0); t.clear();
			t.buffers.color_internal_format = 0x881a; t.buffers.color_type = 0x1406; t.buffers.color_format_size = 8;
			t.buffers.view_count = 2;
			t.call("format and views", false, true, 1); t.call("multiview color", true, true, 1);
			t.call("same multiview", true, true, 0); t.clear(); t.clear();
			t.buffers.view_count = 1;
			t.call("fresh after clear", true, true, 1);
		});
		compare("initial incomplete status clears and retries", [](Trial &t) {
			t.gl.forced_status = GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT;
			t.call("incomplete", true, true, 1);
			require(t.buffers.ids() == "0:0:0" && t.gl.warnings == 1, "Incomplete allocation must clear/warn");
			t.call("retry", true, true, 1); t.call("stable", true, true, 0);
		});
		compare("incomplete attachment addition clears existing depth too", [](Trial &t) {
			t.call("depth", false, true, 1);
			t.gl.forced_status = GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT;
			t.call("failed addition", true, true, 1);
			require(t.buffers.ids() == "0:0:0" && t.gl.textures.empty(), "Failed addition must clear all attachments");
			t.call("retry both", true, true, 1); t.call("stable", true, true, 0);
		});
		compare("nonzero texture name with failed storage allocation", [](Trial &t) {
			t.gl.fail_image = true; t.call("failed image", true, false, 1);
			require(t.buffers.ids() == "0:0:0" && t.gl.warnings == 1, "Failed image storage must not stay cached");
			t.call("retry", true, false, 1); t.call("stable", true, false, 0);
		});
		compare("null framebuffer name, complete default FBO, eventual retry", [](Trial &t) {
			t.gl.fail_fbo = true; t.call("null FBO", true, false, 1);
			require(t.buffers.backbuffer3d.fbo == 0 && t.buffers.backbuffer3d.color != 0,
					"Expected baseline partial state after checking default FBO");
			t.call("new FBO lacks old attachment", true, false, 1);
			require(t.buffers.ids() == "0:0:0", "New unattached FBO must be rejected");
			t.call("retry full allocation", true, false, 1); t.call("stable", true, false, 0);
		});
		compare("null framebuffer name with failed status", [](Trial &t) {
			t.gl.fail_fbo = true; t.gl.forced_status = 0;
			t.call("failed FBO", true, true, 1);
			require(t.buffers.ids() == "0:0:0", "Failed FBO status must clear partial textures");
			t.call("retry", true, true, 1); t.call("stable", true, true, 0);
		});
		for (int failure : {1, 2}) {
			compare(failure == 1 ? "null color name preserves retry" : "null depth name preserves retry", [failure](Trial &t) {
				t.gl.fail_texture_generation = failure;
				t.call("partial complete FBO", true, true, 1);
				require((failure == 1 ? t.buffers.backbuffer3d.color : t.buffers.backbuffer3d.depth) == 0,
						"Requested failed texture must remain missing");
				require(t.gl.accounted.count(0) == 1, "Fixture must expose baseline ID-0 accounting weakness");
				t.call("retry missing texture", true, true, 1); t.call("stable", true, true, 0);
			});
		}
		compare("null color when adding to a depth-only buffer", [](Trial &t) {
			t.call("depth", false, true, 1); t.gl.fail_texture_generation = 2;
			t.call("failed color", true, true, 1);
			t.call("depth still sufficient", false, true, 0);
			t.call("retry color", true, true, 1); t.call("stable", true, true, 0);
		});
		// Deliberate exception to equivalence: after context loss the original
		// observes status 0 and clears IDs, whereas the cache keeps nonzero IDs.
		const auto loss = [](Trial &t) {
			t.call("before loss", true, true, 1);
			t.gl.lost = true;
			t.call("lost context", true, true, 0);
		};
		const auto original = execute<OriginalBuffers>(false, loss);
		const auto patched = execute<PatchedBuffers>(true, loss);
		require(original.ids == "0:0:0" && original.warnings == 1 && original.checks == 2,
				"Original context-loss failure detection changed");
		require(patched.ids != "0:0:0" && patched.warnings == 0 && patched.checks == 1,
				"Expected cached context-loss divergence changed; update documented contract");
		std::cout << "PASS expected context-loss divergence: original clears; cached IDs require reload/invalidation\n";
		std::cout << "PASS " << comparisons << " baseline-equivalence scenarios plus explicit context-loss limitation\n";
		return 0;
	} catch (const std::exception &error) {
		std::cerr << "FAIL " << error.what() << '\n';
		return 1;
	}
}
