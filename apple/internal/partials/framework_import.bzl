# Copyright 2018 The Bazel Authors. All rights reserved.
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

"""Partial implementation for framework import file processing."""

load(
    "@build_bazel_apple_support//lib:apple_support.bzl",
    "apple_support",
)
load(
    "@build_bazel_rules_apple//apple/internal:apple_framework_import.bzl",
    "AppleFrameworkImportInfo",
)
load(
    "@build_bazel_rules_apple//apple/internal:codesigning_support.bzl",
    "codesigning_support",
)
load(
    "@build_bazel_rules_apple//apple/internal:processor.bzl",
    "processor",
)
load(
    "@build_bazel_rules_apple//apple/internal/utils:bundle_paths.bzl",
    "bundle_paths",
)
load(
    "@build_bazel_rules_apple//apple/internal:intermediates.bzl",
    "intermediates",
)
load(
    "@build_bazel_rules_apple//apple/internal:outputs.bzl",
    "outputs",
)
load(
    "@bazel_skylib//lib:partial.bzl",
    "partial",
)
load(
    "@bazel_skylib//lib:paths.bzl",
    "paths",
)

def _framework_import_partial_impl(ctx, targets, targets_to_avoid, extra_binaries):
    """Implementation for the framework import file processing partial."""
    _ignored = [ctx]

    transitive_sets = [
        x[AppleFrameworkImportInfo].framework_imports
        for x in targets
        if AppleFrameworkImportInfo in x
    ]
    files_to_bundle = depset(transitive = transitive_sets).to_list()

    if targets_to_avoid:
        avoid_transitive_sets = [
            x[AppleFrameworkImportInfo].framework_imports
            for x in targets_to_avoid
            if AppleFrameworkImportInfo in x
        ]
        if avoid_transitive_sets:
            avoid_files = depset(transitive = avoid_transitive_sets).to_list()

            # Remove any files present in the targets to avoid from framework files that need to be
            # bundled.
            files_to_bundle = [x for x in files_to_bundle if x not in avoid_files]

    bundle_zips = []
    signed_frameworks_list = []

    # Use the slices produced from the main binary and extra_binaries to determine what slices we
    # need.
    all_binaries = extra_binaries + [outputs.binary(ctx)]

    # Separating our files by framework path, to better address what should be passed in.
    framework_binaries_by_framework = dict()
    files_by_framework = dict()
    for file in files_to_bundle:
        framework_path = bundle_paths.farthest_parent(file.short_path, "framework")
        if not files_by_framework.get(framework_path):
            files_by_framework[framework_path] = []
        if not framework_binaries_by_framework.get(framework_path):
            framework_binaries_by_framework[framework_path] = []

        # Check if this file is a binary to slice and code sign.
        framework_relative_path = paths.relativize(file.short_path, framework_path)
        parent_dir = paths.basename(framework_path)
        framework_relative_dir = paths.dirname(framework_relative_path).strip("/")
        if framework_relative_dir:
            parent_dir = paths.join(parent_dir, framework_relative_dir)

        # Check if this is a macOS path. Format informally described by
        # http://www.synack.net/~bbraun/writing/frameworks.txt . Searching for:
        # ...(framework name).framework/Versions/(version number)/(framework name)
        framework_split_path = framework_relative_path.split("/")

        if len(framework_split_path) > 3:
            if (framework_split_path[-3] == "Versions" and
                paths.replace_extension(framework_split_path[-4], "") == file.basename):
                framework_binaries_by_framework[framework_path].append(file)
                continue

        # Check if this is an iOS/tvOS/watchOS path.
        if paths.replace_extension(parent_dir, "") == file.basename:
            framework_binaries_by_framework[framework_path].append(file)
            continue

        files_by_framework[framework_path].append(file)

    for framework_path in files_by_framework.keys():
        framework_binaries = framework_binaries_by_framework[framework_path]
        framework_relative_path = paths.relativize(framework_binaries[0].short_path, framework_path)

        parent_dir = paths.basename(framework_path)
        framework_relative_dir = paths.dirname(framework_relative_path).strip("/")
        if framework_relative_dir:
            parent_dir = paths.join(parent_dir, framework_relative_dir)

        temp_path = paths.join("_imported_frameworks/", parent_dir)

        temp_framework_bundle = intermediates.directory(
            ctx.actions,
            ctx.label.name,
            temp_path,
        )

        framework_zip = intermediates.file(
            ctx.actions,
            ctx.label.name,
            temp_path + ".zip",
        )

        args = []

        for framework_binary in framework_binaries:
            args.append("--framework_binary")
            args.append(framework_binary.path)

        for binary in all_binaries:
            args.append("--binary")
            args.append(binary.path)

        args.append("--output_zip")
        args.append(framework_zip.path)

        args.append("--temp_path")
        args.append(temp_framework_bundle.path)

        for file in files_by_framework[framework_path]:
            args.append("--framework_file")
            args.append(file.path)

        codesign_args = codesigning_support.codesigning_args(
            ctx,
            entitlements = None,
            full_archive_path = temp_framework_bundle.path,
            is_framework = True,
        )
        args.extend(codesign_args)

        # Inputs of action are all the framework files, plus any of the imports needed to do
        # framework slicing, plus any of the inputs needed to do signing.
        apple_support.run(
            ctx,
            inputs = files_by_framework[framework_path] + framework_binaries_by_framework[framework_path] + all_binaries,
            tools = [ctx.executable._codesigningtool],
            executable = ctx.executable._dynamic_framework_slicer,
            outputs = [temp_framework_bundle, framework_zip],
            arguments = args,
            mnemonic = "DynamicFrameworkSlicerWithCodesigningAndZipping",
        )

        bundle_zips.append(
            (processor.location.framework, None, depset([framework_zip])),
        )
        signed_frameworks_list.append(parent_dir)

    # TODO(nglevin): When testing, check if we have test coverage of the dynamic fmwk import
    # code paths in the apple_rules today, and if we need to create a special dynamic fmwk
    # that can be imported for testing. Might be an objc_library that gets copied into a
    # .framework folder with an Info.plist and other bits so that we don't have to recompile the
    # test framework for future architecture (binary slice) changes on Apple platforms.

    # TODO(nglevin): Might have to make one or both of these recursive, if there are any
    # frameworks-in-frameworks cases that the partials have to handle (unsure, haven't confirmed
    # with Tony or Thomas yet).
    return struct(
        bundle_zips = bundle_zips,
        signed_frameworks = depset(signed_frameworks_list),
    )

def framework_import_partial(targets, targets_to_avoid = [], extra_binaries = []):
    """Constructor for the framework import file processing partial.

    This partial propagates framework import file bundle locations. The files are collected through
    the framework_import_aspect aspect.

    Args:
        targets: The list of targets through which to collect the framework import files.
        targets_to_avoid: The list of targets that may already be bundling some of the frameworks,
            to be used when deduplicating frameworks already bundled.
        extra_binaries: Extra binaries to consider when collecting which archs should be
            preserved in the imported dynamic frameworks.

    Returns:
        A partial that returns the bundle location of the framework import files.
    """
    return partial.make(
        _framework_import_partial_impl,
        targets = targets,
        targets_to_avoid = targets_to_avoid,
        extra_binaries = extra_binaries,
    )
