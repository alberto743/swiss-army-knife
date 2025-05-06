#!/usr/bin/env python3

# SPDX-FileCopyrightText: © 2025 alberto743
#
# SPDX-License-Identifier: MPL-2.0

'''Extract variables employed in Fortran units'''


tags_dump = {
    "sym_tree": "symtree:",
    "symbol": "symbol:",
    "attributes": "attributes:",
    "code": "code:",
    "variable": "VARIABLE",
    "parameter": "PARAMETER",
    "dummy": "DUMMY",
    "use_association": "USE-ASSOC",
    "implicit_variable": "IMPLICIT-TYPE",
}


def get_gfortran_dumporiginal(sourcefile, modfiles_dir=None, output_dir=None):
    from pathlib import Path
    import subprocess


    modfiles_opts = list()
    if modfiles_dir is not None:
        modfiles_opts = ["-J", modfiles_dir]
    outdir_opts = list()
    if output_dir is not None:
        outdir_opts = ["-o", str(Path(output_dir) / (Path(sourcefile).stem + '.o'))]
    try:
        result = subprocess.run(
            ["gfortran", "-fdump-fortran-original", *modfiles_opts, *outdir_opts,  "-c", sourcefile],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True
        )
    except subprocess.CalledProcessError as e:
        if e.returncode == 1:
            print("gfortran failed to compile the source file.")
            print("Error message:", e.stderr)
            return None
        else:
            print("An unexpected error occurred.")
            print("Error message:", e.stderr)
            return None
    return result.stdout


def extract_variables_gfortran_dumporiginal(gfordump):
    import re


    grp_paran = re.compile(r'\(([^)]+)')
    variables = list()
    parameters = list()
    found = False

    for line in gfordump.splitlines():
        items = line.split()
        if not bool(items):
            continue

        if items[0] == tags_dump["code"]:
            break

        if items[0] == tags_dump["sym_tree"] and tags_dump["symbol"] in items:
            found = True
            symbol = items[items.index(tags_dump["symbol"]) + 1][1:-1]

        if found:
            if tags_dump["attributes"] in items:
                found = False
                attrs = list()
                for attr_i in items[1:]:
                    if attr_i.startswith('('):
                        attrs.append(attr_i[1:])
                    elif attr_i.endswith(')'):
                        attrs.append(attr_i[:-1])
                    else:
                        attrs.append(attr_i)

                use_association_finder = [tags_dump["use_association"] in elem for elem in attrs]
                if any(use_association_finder):
                    use_association = attrs[use_association_finder.index(True)]
                    mod_name = grp_paran.search(use_association).group(1)
                else:
                    mod_name = None

                if attrs[0] == tags_dump["parameter"]:
                    parameters.append((symbol, mod_name))

                elif attrs[0] == tags_dump["variable"]:
                    if any([e.startswith(tags_dump["dummy"]) for e in attrs]):
                        dummy = True
                    else:
                        dummy = False
                    if tags_dump["implicit_variable"] in attrs:
                        implicit_type = True
                    else:
                        implicit_type = False
                    variables.append((symbol, dummy, mod_name, implicit_type))

    return tuple(variables), tuple(parameters)


def main():
    import argparse
    import pandas as pd
    from pathlib import Path


    parser = argparse.ArgumentParser(description="Extract variables from a Fortran source file.")
    parser.add_argument("sourcefile", help="Path to the Fortran source file")
    parser.add_argument(
        "-o", "--output-dir",
        help="Directory to store the output files",
        default=None
    )
    parser.add_argument(
        "-j", "--modfiles-dir",
        help="Directory to store the module files",
        default=None
    )
    parser.add_argument(
        "-w", "--write",
        help="Write the output to a file",
        action="store_true",
        default=False
    )
    parser.add_argument(
        "-v", "--verbose",
        help="Enable listing output",
        action="store_true",
        default=False
    )
    args = parser.parse_args()

    gfortran_stdout = get_gfortran_dumporiginal(args.sourcefile, args.modfiles_dir, args.output_dir)
    if gfortran_stdout is None:
        exit(1)
    vars, pars = extract_variables_gfortran_dumporiginal(gfortran_stdout)
    variables = pd.DataFrame(vars, columns=["Name", "Dummy", "Module", "Implicit"]).set_index("Name")
    parameters = pd.DataFrame(pars, columns=["Name", "Module"]).set_index("Name")

    if not variables.empty:
        if args.verbose:
            print(">>> Variables <<<")
            print(variables.to_string())
        if args.write:
            variables.to_csv(Path(args.sourcefile).stem + ".variables.csv", index=True)

    if not parameters.empty:
        if args.verbose:
            print(">>> Parameters <<<")
            print(parameters.to_string())
        if args.write:
            parameters.to_csv(Path(args.sourcefile).stem + ".parameters.csv", index=True)


if __name__ == "__main__":
    main()
