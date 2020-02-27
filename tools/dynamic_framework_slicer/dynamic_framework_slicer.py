# Lint as: python2, python3
# Copyright 2020 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# TODO(nglevin): Update header docs with copyright info, usage info.

import os
import shutil
import subprocess
import sys
import time

from build_bazel_rules_apple.tools.codesigningtool import codesigningtool

_PY3 = sys.version_info[0] == 3


# TODO(nglevin): Consider replacing with the execute tool, from the following:
# from build_bazel_rules_apple.tools.wrapper_common import execute
#
# This might have some issues with error reporting. If so, consider moving this
# implementation to that python library, and share between codesigningtool.py
# and here.
def _check_output(args, inputstr=None):
  proc = subprocess.Popen(
      args,
      stdin=subprocess.PIPE,
      stdout=subprocess.PIPE,
      stderr=subprocess.PIPE)
  stdout, stderr = proc.communicate(input=inputstr)

  # Only decode the output for Py3 so that the output type matches
  # the native string-literal type. This prevents Unicode{Encode,Decode}Errors
  # in Py2.
  if _PY3:
    # The invoked tools don't specify what encoding they use, so for lack of a
    # better option, just use utf8 with error replacement. This will replace
    # incorrect utf8 byte sequences with '?', which avoids UnicodeDecodeError
    # from raising.
    stdout = stdout.decode("utf8", "replace")
    stderr = stderr.decode("utf8", "replace")

  if proc.returncode != 0:
    # print the stdout and stderr, as the exception won't print it.
    print("ERROR:{stdout}\n\n{stderr}".format(stdout=stdout, stderr=stderr))
    raise subprocess.CalledProcessError(proc.returncode, args)
  return stdout, stderr


def _invoke_lipo(binary_path, binary_slices, output_path):
  cmd = ["xcrun", "lipo", binary_path]
  for binary_slice in binary_slices:
    cmd.extend(["-extract", binary_slice])
  cmd.extend(["-output", output_path])
  stdout, stderr = _check_output(cmd)
  if stdout:
    print(stdout)
  if stderr:
    print(stderr)


def _find_archs_for_binaries(binary_list):
  found_architectures = set()

  for binary in binary_list:
    cmd = ["xcrun", "lipo", "-info", binary]
    stdout, stderr = _check_output(cmd)
    if stderr:
      print(stderr)
      continue
    if not stdout:
      print("Internal Error: Did not receive output from lipo for inputs: " +
            " ".join(cmd))
      continue

    cut_output = stdout.split(":")
    if len(cut_output) < 3:
      print("Internal Error: Unexpected output from lipo, received: " + stdout)
      continue

    archs_found = cut_output[2].strip().split(" ")
    if not archs_found:
      print("Internal Error: Could not find architecture for binary: " + binary)
      continue

    for arch_found in archs_found:
      found_architectures.add(arch_found)

  return found_architectures


def _sign_framework(args):
  codesigningtool.main(args)


def _zip_framework(framework_temp_path, output_zip_path):
  zip_epoch_timestamp = 946684800  # 2000-01-01 00:00
  if os.path.exists(framework_temp_path):
    for root, dirs, files in os.walk(framework_temp_path):
      for file_name in files:
        file_path = os.path.join(root, file_name)
        timestamp = zip_epoch_timestamp + time.timezone
        os.utime(file_path, (timestamp, timestamp))
  shutil.make_archive(os.path.splitext(output_zip_path)[0], "zip",
                      os.path.dirname(framework_temp_path),
                      os.path.basename(framework_temp_path))


def _relpath_from_framework(framework_absolute_path):
  framework_dir = None
  parent_dir = os.path.dirname(framework_absolute_path)
  while parent_dir != "/" and framework_dir is None:
    if parent_dir.endswith(".framework"):
      framework_dir = parent_dir
    else:
      parent_dir = os.path.dirname(parent_dir)

  if parent_dir == "/":
    print("Internal Error: Could not find path in framework: " +
          framework_absolute_path)
    return None

  return os.path.relpath(framework_absolute_path, framework_dir)


def _copy_framework_file(framework_file, output_path):
  path_from_framework = _relpath_from_framework(framework_file)
  if not path_from_framework:
    return

  temp_framework_path = os.path.join(output_path, path_from_framework)
  temp_framework_dirs = os.path.dirname(temp_framework_path)
  if not os.path.exists(temp_framework_dirs):
    os.mkdir(temp_framework_dirs)
  shutil.copy2(framework_file, temp_framework_path)


def _strip_framework_binary(framework_binary, output_path, slices_needed):
  if not slices_needed:
    print("Internal Error: Did not specify any slices needed: " +
          " ".join(binary_list))
    return

  path_from_framework = _relpath_from_framework(framework_binary)
  if not path_from_framework:
    return

  temp_framework_path = os.path.join(output_path, path_from_framework)

  _invoke_lipo(framework_binary, slices_needed, temp_framework_path)


def main(argv):
  parser = codesigningtool.generate_arg_parser()
  parser.add_argument(
      "--framework_binary", type=str, required=True, action="append",
      help="TODO"
  )
  parser.add_argument(
      "--binary", type=str, required=True, action="append", help="TODO"
  )
  parser.add_argument(
      "--framework_file", type=str, action="append", help="TODO"
  )
  parser.add_argument(
      "--temp_path", type=str, required=True, help="TODO"
  )
  parser.add_argument(
      "--output_zip", type=str, required=True, help="TODO"
  )
  args = parser.parse_args()

  all_binary_archs = _find_archs_for_binaries(args.binary)
  framework_archs = _find_archs_for_binaries(args.framework_binary)

  if not all_binary_archs:
    return 1
  if not framework_archs:
    return 1

  for framework_binary in args.framework_binary:
    # If the imported framework is single architecture, and can't be lipoed, or
    # if the binary architectures match the framework architectures perfectly,
    # treat as a copy instead of a lipo operation.
    if len(framework_archs) == 1 or all_binary_archs == framework_archs:
      _copy_framework_file(framework_binary, args.temp_path)
    else:
      slices_needed = framework_archs.intersection(all_binary_archs)
      if not slices_needed:
        print("Error: Precompiled framework does not share any binary "
              "architectures with the binaries that were built.")
        return 1
      _strip_framework_binary(framework_binary, args.temp_path, slices_needed)

  if args.framework_file:
    for framework_file in args.framework_file:
      _copy_framework_file(framework_file, args.temp_path)

  _sign_framework(args)

  _zip_framework(args.temp_path, args.output_zip)


if __name__ == "__main__":
  sys.exit(main(sys.argv))
