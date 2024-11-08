#include <string>
#include <map>
#include <iostream>
#include <lua.hpp>
#include "common/ceph_context.h"
#include "common/dout.h"
#include "rgw_lua_utils.h"
#include "rgw_lua_version.h"
#include "rgw_sal.h"

#define dout_subsys ceph_subsys_rgw

namespace rgw::lua {

// TODO - add the folowing generic functions
// lua_push(lua_State* L, const std::string& str)
// template<typename T> lua_push(lua_State* L, const std::optional<T>& val)
// lua_push(lua_State* L, const ceph::real_time& tp)

constexpr const char* RGWDebugLogAction{"RGWDebugLog"};
constexpr const char* RGWUpdateObjectMetadataAction{"RGWUpdateObjectMetadata"};

int RGWDebugLog(lua_State* L) 
{
  auto cct = reinterpret_cast<CephContext*>(lua_touserdata(L, lua_upvalueindex(1)));

  auto message = luaL_checkstring(L, 1);
  ldout(cct, 20) << "Lua INFO: " << message << dendl;
  return 0;
}

int RGWUpdateObjectMetadata(lua_State* L)
{
    int op_ret;
    auto store = reinterpret_cast<rgw::sal::Store*>(lua_touserdata(L, lua_upvalueindex(1)));
    auto s = reinterpret_cast<req_state*>(lua_touserdata(L, lua_upvalueindex(2)));
    std::unique_ptr<rgw::sal::Bucket> bucket;

    ldout(s->cct, 20) << "lua in RGWUpdateObjectMetadata" << dendl;

    int r = store->get_bucket(nullptr, s->user.get(), s->user->get_tenant(), s->bucket_name, &bucket, s->yield);
    if (r < 0) {
        ldout(s->cct, 20) << "lua no bucket, continue" << dendl;
        return 0;
    }

    ldout(s->cct, 20) << "lua bucket" << s->bucket << dendl;

    auto object_name = luaL_checkstring(L, 1);
    auto object_metadata_key = luaL_checkstring(L, 2);
    auto object_metadata_value = luaL_checkstring(L, 3);

    if (object_name == nullptr || strlen(object_name) == 0) {
        ldout(s->cct, 20) << "lua object_name empty" << dendl;
        return 0;
    }

    if (object_metadata_key == nullptr || strlen(object_metadata_key) == 0) {
        ldout(s->cct, 20) << "lua object_metadata_key empty" << dendl;
        return 0;
    }

    if (object_metadata_value == nullptr || strlen(object_metadata_value) == 0) {
        ldout(s->cct, 20) << "lua object_metadata_value empty" << dendl;
        return 0;
    }

    std::unique_ptr<rgw::sal::Object> object = bucket->get_object(std::string(object_name));

    ldout(s->cct, 20) << "lua object_name " << object_name << dendl;
    ldout(s->cct, 20) << "lua object_name key " << object_metadata_key << dendl;
    ldout(s->cct, 20) << "lua object_name value " << object_metadata_value << dendl;

    rgw_obj target_obj;
    op_ret = object->get_obj_attrs(s->obj_ctx, s->yield, s, &target_obj);
    if (op_ret < 0) {
        ldout(s->cct, 20) << "lua could not get object attributes" << dendl;
        return 0;
    }
    rgw::sal::Attrs attrs = object->get_attrs();
    auto tags = attrs.find(RGW_ATTR_TAGS);
    if (tags != attrs.end()){
        ldout(s->cct, 20) << "lua tags" << dendl;
        ldout(s->cct, 20) << "lua TAG second " << tags->second.to_str() << dendl;

        RGWObjTags obj_tags;
        try {
            auto it = tags->second.cbegin();
            ::decode(obj_tags, it);
        } catch(buffer::error &e) {
            ldout(s->cct, 20) << "lua tag second error " << e.what() << dendl;
        }
        for (auto& tag: obj_tags.get_tags()) {
            ldout(s->cct, 20) << "tag OBJ tag first " << tag.first << dendl;
            ldout(s->cct, 20) << "tag OBJ tag second " << tag.second << dendl;
        }
        obj_tags.add_tag("test1", "test2");

        bufferlist tags_bl;
        obj_tags.encode(tags_bl);
        // tags_bl.append();
        op_ret = object->modify_obj_attrs(s->obj_ctx, RGW_ATTR_TAGS, tags_bl, s->yield, s);

    }

    ldout(s->cct, 20) << "lua im here" << dendl;

    return 0;
}

void create_debug_action(lua_State* L, CephContext* cct) {
  lua_pushlightuserdata(L, cct);
  lua_pushcclosure(L, RGWDebugLog, ONE_UPVAL);
  lua_setglobal(L, RGWDebugLogAction);
}

void create_update_object_metatdata_action(lua_State* L, rgw::sal::Store* store, req_state* s) {
  lua_pushlightuserdata(L, store);
  lua_pushlightuserdata(L, s);

  lua_pushcclosure(L, RGWUpdateObjectMetadata, TWO_UPVALS);
  lua_setglobal(L, RGWUpdateObjectMetadataAction);
}

void stack_dump(lua_State* L) {
  int top = lua_gettop(L);
  std::cout << std::endl << " ----------------  Stack Dump ----------------" << std::endl;
  std::cout << "Stack Size: " << top << std::endl;
  for (int i = 1, j = -top; i <= top; i++, j++) {
    std::cout << "[" << i << "," << j << "]: " << luaL_tolstring(L, i, NULL) << std::endl;
    lua_pop(L, 1);
  }
  std::cout << "--------------- Stack Dump Finished ---------------" << std::endl;
}

void set_package_path(lua_State* L, const std::string& install_dir) {
  if (install_dir.empty()) {
    return;
  }
  lua_getglobal(L, "package");
  if (!lua_istable(L, -1)) {
    return;
  }
  const auto path = install_dir+"/share/lua/"+CEPH_LUA_VERSION+"/?.lua";
  pushstring(L, path);
  lua_setfield(L, -2, "path");
  
  const auto cpath = install_dir+"/lib/lua/"+CEPH_LUA_VERSION+"/?.so;"+install_dir+"/lib64/lua/"+CEPH_LUA_VERSION+"/?.so";
  pushstring(L, cpath);
  lua_setfield(L, -2, "cpath");
}

void open_standard_libs(lua_State* L) {
  luaL_openlibs(L);
  unsetglobal(L, "load");
  unsetglobal(L, "loadfile");
  unsetglobal(L, "loadstring");
  unsetglobal(L, "dofile");
  unsetglobal(L, "debug");
  // remove os.exit()
  lua_getglobal(L, "os");
  lua_pushstring(L, "exit");
  lua_pushnil(L);
  lua_settable(L, -3);
}

}
