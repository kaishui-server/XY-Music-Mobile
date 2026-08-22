//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <quickjs_engine/quickjs_engine_plugin.h>
#include <record_linux/record_linux_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) quickjs_engine_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "QuickjsEnginePlugin");
  quickjs_engine_plugin_register_with_registrar(quickjs_engine_registrar);
  g_autoptr(FlPluginRegistrar) record_linux_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "RecordLinuxPlugin");
  record_linux_plugin_register_with_registrar(record_linux_registrar);
}
