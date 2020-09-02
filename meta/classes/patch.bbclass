#
# Imported from openembedded-core
#
# Copyright (C) 2006  OpenedHand LTD
# Copyright (c) Siemens AG, 2019
#
# SPDX-License-Identifier: MIT
#

# Point to an empty file so any user's custom settings don't break things
QUILTRCFILE ?= "${WORKDIR}/.quiltrc"

PATCH_GIT_USER_NAME ?= "Isar"
PATCH_GIT_USER_EMAIL ?= "isar.patch@isar"

inherit terminal

python () {
    if d.getVar('PATCHTOOL') == 'git' and d.getVar('PATCH_COMMIT_FUNCTIONS') == '1':
        extratasks = bb.build.tasksbetween('do_unpack', 'do_patch', d)
        try:
            extratasks.remove('do_unpack')
        except ValueError:
            # For some recipes do_unpack doesn't exist, ignore it
            pass

        d.appendVarFlag('do_patch', 'prefuncs', ' patch_task_patch_prefunc')
        for task in extratasks:
            d.appendVarFlag(task, 'postfuncs', ' patch_task_postfunc')
}

python patch_task_patch_prefunc() {
    # Prefunc for do_patch
    srcsubdir = d.getVar('S')

    workdir = os.path.abspath(d.getVar('WORKDIR'))
    testsrcdir = os.path.abspath(srcsubdir)
    if (testsrcdir + os.sep).startswith(workdir + os.sep):
        # Double-check that either workdir or S or some directory in-between is a git repository
        found = False
        while testsrcdir != workdir:
            if os.path.exists(os.path.join(testsrcdir, '.git')):
                found = True
                break
            if testsrcdir == workdir:
                break
            testsrcdir = os.path.dirname(testsrcdir)
        if not found:
            bb.fatal('PATCHTOOL = "git" set for source tree that is not a git repository. Refusing to continue as that may result in commits being made in your metadata repository.')

    patchdir = os.path.join(srcsubdir, 'patches')
    if os.path.exists(patchdir):
        if os.listdir(patchdir):
            d.setVar('PATCH_HAS_PATCHES_DIR', '1')
        else:
            os.rmdir(patchdir)
}

python patch_task_postfunc() {
    # Prefunc for task functions between do_unpack and do_patch
    import oe.patch
    import shutil
    func = d.getVar('BB_RUNTASK')
    srcsubdir = d.getVar('S')

    if os.path.exists(srcsubdir):
        if func == 'do_patch':
            haspatches = (d.getVar('PATCH_HAS_PATCHES_DIR') == '1')
            patchdir = os.path.join(srcsubdir, 'patches')
            if os.path.exists(patchdir):
                shutil.rmtree(patchdir)
                if haspatches:
                    stdout, _ = bb.process.run('git status --porcelain patches', cwd=srcsubdir)
                    if stdout:
                        bb.process.run('git checkout patches', cwd=srcsubdir)
        stdout, _ = bb.process.run('git status --porcelain .', cwd=srcsubdir)
        if stdout:
            useroptions = []
            oe.patch.GitApplyTree.gitCommandUserOptions(useroptions, d=d)
            bb.process.run('git add .; git %s commit -a -m "Committing changes from %s\n\n%s"' % (' '.join(useroptions), func, oe.patch.GitApplyTree.ignore_commit_prefix + ' - from %s' % func), cwd=srcsubdir)
}

def src_patches(d, all=False, expand=True):
    import oe.patch
    return oe.patch.src_patches(d, all, expand)

def should_apply(parm, d):
    """Determine if we should apply the given patch"""
    import oe.patch
    return oe.patch.should_apply(parm, d)

should_apply[vardepsexclude] = "DATE SRCDATE"

def patch_do_debian_quilt(patchdir, d):
    import oe.patch
    class DummyPatchSet(oe.patch.PatchSet):
        def Clean(self):
            True

        def Import(self, patch, force):
            os.putenv('QUILT_PATCHES', 'debian/patches')
            # push all so we are on top of debian
            pushed = False
            if os.path.exists(os.path.join(self.dir, 'debian/patches/series')):
                oe.patch.runcmd(["quilt", "push", "-a"], self.dir)
                pushed = True
            oe.patch.runcmd(["quilt", "import", "-f", os.path.join(d.getVar('WORKDIR'), os.path.basename(patch['file']))], self.dir)
            if pushed:
                oe.patch.runcmd(["quilt", "pop", "-a"], self.dir)

        def Push(self, force = False):
            True

    return DummyPatchSet(patchdir, d)

python patch_do_patch() {
    import sys

    oe_lib_path = os.path.join(d.getVar('LAYERDIR_core'), 'lib')
    sys.path.insert(0, oe_lib_path)

    import oe.patch

    patchsetmap = {
        "patch": oe.patch.PatchTree,
        "quilt": oe.patch.QuiltTree,
        "git": oe.patch.GitApplyTree,
    }

    cls = patchsetmap[d.getVar('PATCHTOOL') or 'quilt']

    resolvermap = {
        "noop": oe.patch.NOOPResolver,
        "user": oe.patch.UserResolver,
    }

    rcls = resolvermap[d.getVar('PATCHRESOLVE') or 'user']

    classes = {}

    s = d.getVar('S')

    debianformat = os.path.join(s, 'debian/source/format')
    if os.path.exists(debianformat) and d.getVar('PATCHTOOL') != 'quilt':
        with open(debianformat, 'r+') as f:
            if f.readline() == '3.0 (quilt)\n':
                cls = patch_do_debian_quilt

    os.putenv('PATH', d.getVar('PATH'))

    # We must use one TMPDIR per process so that the "patch" processes
    # don't generate the same temp file name.

    import tempfile
    process_tmpdir = tempfile.mkdtemp()
    os.environ['TMPDIR'] = process_tmpdir

    for patch in src_patches(d):
        _, _, local, _, _, parm = bb.fetch.decodeurl(patch)

        if "patchdir" in parm:
            patchdir = parm["patchdir"]
            if not os.path.isabs(patchdir):
                patchdir = os.path.join(s, patchdir)
        else:
            patchdir = s

        if not patchdir in classes:
            patchset = cls(patchdir, d)
            resolver = rcls(patchset, oe_terminal)
            classes[patchdir] = (patchset, resolver)
            patchset.Clean()
        else:
            patchset, resolver = classes[patchdir]

        bb.note("Applying patch '%s' (%s)" % (parm['patchname'], oe.path.format_display(local, d)))
        try:
            patchset.Import({"file":local, "strippath": parm['striplevel']}, True)
        except Exception as exc:
            bb.utils.remove(process_tmpdir, True)
            bb.fatal(str(exc))
        try:
            resolver.Resolve()
        except bb.BBHandledException as e:
            bb.utils.remove(process_tmpdir, True)
            bb.fatal(str(e))

    bb.utils.remove(process_tmpdir, True)
    del os.environ['TMPDIR']
}
patch_do_patch[vardepsexclude] = "PATCHRESOLVE"

addtask patch after do_unpack
do_patch[umask] = "022"
do_patch[dirs] = "${WORKDIR}"

EXPORT_FUNCTIONS do_patch
