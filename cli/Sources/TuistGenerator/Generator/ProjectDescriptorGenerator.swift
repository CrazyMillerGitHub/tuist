import Foundation
import TuistCore
import TuistSupport
import XcodeGraph
import XcodeProj

protocol ProjectDescriptorGenerating: AnyObject {
    /// Generates the given project.
    /// - Parameters:
    ///   - project: Project to be generated.
    ///   - graphTraverser: Graph traverser.
    /// - Returns: Generated project descriptor
    func generate(project: Project, graphTraverser: GraphTraversing) async throws -> ProjectDescriptor
}

final class ProjectDescriptorGenerator: ProjectDescriptorGenerating {
    // MARK: - ProjectConstants

    struct ProjectConstants {
        var objectVersion: UInt
        var archiveVersion: UInt

        static var xcode10: ProjectConstants {
            ProjectConstants(
                objectVersion: 50,
                archiveVersion: Xcode.LastKnown.archiveVersion
            )
        }

        static var xcode11: ProjectConstants {
            ProjectConstants(
                objectVersion: 52,
                archiveVersion: Xcode.LastKnown.archiveVersion
            )
        }

        static var xcode13: ProjectConstants {
            ProjectConstants(
                objectVersion: 55,
                archiveVersion: Xcode.LastKnown.archiveVersion
            )
        }
    }

    // MARK: - Attributes

    /// Generator for the project targets.
    let targetGenerator: TargetGenerating

    /// Generator for the project configuration.
    let configGenerator: ConfigGenerating

    /// Generator for the project schemes.
    let schemeDescriptorsGenerator: SchemeDescriptorsGenerating

    /// Fetcher for the project known asset tags associated with on-demand resources.
    let knownAssetTagsFetcher: KnownAssetTagsFetching

    // MARK: - Init

    /// Initializes the project generator with its attributes.
    ///
    /// - Parameters:
    ///   - targetGenerator: Generator for the project targets.
    ///   - configGenerator: Generator for the project configuration.
    ///   - schemeDescriptorsGenerator: Generator for the project schemes.
    ///   - knownAssetTagsFetcher: Fetcher for the project known asset tags associated with on-demand resources.
    init(
        targetGenerator: TargetGenerating = TargetGenerator(),
        configGenerator: ConfigGenerating = ConfigGenerator(),
        schemeDescriptorsGenerator: SchemeDescriptorsGenerating = SchemeDescriptorsGenerator(),
        knownAssetTagsFetcher: KnownAssetTagsFetching = KnownAssetTagsFetcher()
    ) {
        self.targetGenerator = targetGenerator
        self.configGenerator = configGenerator
        self.schemeDescriptorsGenerator = schemeDescriptorsGenerator
        self.knownAssetTagsFetcher = knownAssetTagsFetcher
    }

    // MARK: - ProjectGenerating

    // swiftlint:disable:next function_body_length
    func generate(
        project: Project,
        graphTraverser: GraphTraversing
    ) async throws -> ProjectDescriptor {
        Logger.current.notice("Generating project \(project.name)")

        let selfRef = XCWorkspaceDataFileRef(location: .current(""))
        let selfRefFile = XCWorkspaceDataElement.file(selfRef)
        let workspaceData = XCWorkspaceData(children: [selfRefFile])
        let workspace = XCWorkspace(data: workspaceData)
        let projectConstants = try determineProjectConstants()
        let pbxproj = PBXProj(
            objectVersion: projectConstants.objectVersion,
            archiveVersion: projectConstants.archiveVersion,
            classes: [:]
        )
        let groups = ProjectGroups.generate(project: project, pbxproj: pbxproj)
        let fileElements = ProjectFileElements()
        try fileElements.generateProjectFiles(
            project: project,
            graphTraverser: graphTraverser,
            groups: groups,
            pbxproj: pbxproj
        )
        let configurationList = try await configGenerator.generateProjectConfig(
            project: project,
            pbxproj: pbxproj,
            fileElements: fileElements
        )
        let pbxProject = try generatePbxproject(
            project: project,
            projectFileElements: fileElements,
            configurationList: configurationList,
            groups: groups,
            pbxproj: pbxproj
        )

        let nativeTargets = try await generateTargets(
            project: project,
            pbxproj: pbxproj,
            pbxProject: pbxProject,
            fileElements: fileElements,
            graphTraverser: graphTraverser
        )

        generateTestTargetIdentity(
            project: project,
            pbxproj: pbxproj,
            pbxProject: pbxProject
        )

        try generateSwiftPackageReferences(
            project: project,
            pbxproj: pbxproj,
            pbxProject: pbxProject
        )

        let generatedProject = GeneratedProject(
            pbxproj: pbxproj,
            path: project.xcodeProjPath,
            targets: nativeTargets,
            name: project.xcodeProjPath.basename
        )

        let schemes = try schemeDescriptorsGenerator.generateProjectSchemes(
            project: project,
            generatedProject: generatedProject,
            graphTraverser: graphTraverser
        )

        groups.removeEmptyAuxiliaryGroups()

        let xcodeProj = XcodeProj(workspace: workspace, pbxproj: pbxproj)
        return ProjectDescriptor(
            path: project.path,
            xcodeprojPath: project.xcodeProjPath,
            xcodeProj: xcodeProj,
            schemeDescriptors: schemes,
            sideEffectDescriptors: []
        )
    }

    // MARK: - Fileprivate

    private func generatePbxproject(
        project: Project,
        projectFileElements: ProjectFileElements,
        configurationList: XCConfigurationList,
        groups: ProjectGroups,
        pbxproj: PBXProj
    ) throws -> PBXProject {
        let defaultKnownRegions = project.defaultKnownRegions ?? ["en", "Base"]
        let knownRegions = Set(defaultKnownRegions + projectFileElements.knownRegions).sorted()
        let developmentRegion = project.developmentRegion ?? Xcode.Default.developmentRegion
        let attributes = generateAttributes(project: project)
        let pbxProject = PBXProject(
            name: project.name,
            buildConfigurationList: configurationList,
            compatibilityVersion: Xcode.Default.compatibilityVersion,
            preferredProjectObjectVersion: nil,
            minimizedProjectReferenceProxies: nil,
            mainGroup: groups.sortedMain,
            developmentRegion: developmentRegion,
            hasScannedForEncodings: 0,
            knownRegions: knownRegions,
            productsGroup: groups.products,
            projectDirPath: "",
            projects: [],
            projectRoots: [],
            targets: [],
            attributes: attributes
        )
        pbxproj.add(object: pbxProject)
        pbxproj.rootObject = pbxProject
        return pbxProject
    }

    private func generateTargets(
        project: Project,
        pbxproj: PBXProj,
        pbxProject: PBXProject,
        fileElements: ProjectFileElements,
        graphTraverser: GraphTraversing
    ) async throws -> [String: PBXNativeTarget] {
        var nativeTargets: [String: PBXNativeTarget] = [:]
        for target in project.targets.values.sorted() {
            let nativeTarget = try await targetGenerator.generateTarget(
                target: target,
                project: project,
                pbxproj: pbxproj,
                pbxProject: pbxProject,
                projectSettings: project.settings,
                fileElements: fileElements,
                path: project.path,
                graphTraverser: graphTraverser
            )
            nativeTargets[target.name] = nativeTarget
        }

        // Target dependencies
        try targetGenerator.generateTargetDependencies(
            path: project.path,
            targets: Array(project.targets.values),
            nativeTargets: nativeTargets,
            graphTraverser: graphTraverser
        )
        return nativeTargets
    }

    private func generateTestTargetIdentity(
        project _: Project,
        pbxproj: PBXProj,
        pbxProject: PBXProject
    ) {
        func testTargetName(_ target: PBXTarget) -> String? {
            guard let buildConfigurations = target.buildConfigurationList?.buildConfigurations else {
                return nil
            }

            return buildConfigurations
                .compactMap { $0.buildSettings["TEST_TARGET_NAME"]?.stringValue }
                .first
        }

        let testTargets = pbxproj.nativeTargets.filter { $0.productType == .uiTestBundle || $0.productType == .unitTestBundle }

        for testTarget in testTargets {
            guard let name = testTargetName(testTarget) else {
                continue
            }

            guard let target = pbxproj.targets(named: name).first else {
                continue
            }

            var attributes = pbxProject.targetAttributes[testTarget] ?? [:]

            attributes["TestTargetID"] = .targetReference(target)

            pbxProject.setTargetAttributes(attributes, target: testTarget)
        }
    }

    private func generateSwiftPackageReferences(project: Project, pbxproj: PBXProj, pbxProject: PBXProject) throws {
        var remotePackageReferences: [String: XCRemoteSwiftPackageReference] = [:]
        var localPackageReferences: [String: XCLocalSwiftPackageReference] = [:]

        for package in project.packages {
            switch package {
            case let .local(path):

                let reference = PBXFileReference(
                    sourceTree: .group,
                    name: path.components.last,
                    lastKnownFileType: "folder",
                    path: path.relative(to: project.sourceRootPath).pathString
                )

                let packageReference = XCLocalSwiftPackageReference(
                    relativePath: path.pathString
                )
                pbxproj.add(object: packageReference)
                localPackageReferences[path.pathString] = packageReference

                pbxproj.add(object: reference)

                if let existingPackageGroup = try pbxproj.rootGroup()?.group(named: "Packages") {
                    existingPackageGroup.children.append(reference)
                } else {
                    let packageGroup = try pbxproj.rootGroup()?.addGroup(named: "Packages", options: .withoutFolder)
                    packageGroup?.first?.children.append(reference)
                }

            case let .remote(url: url, requirement: requirement):
                let packageReference = XCRemoteSwiftPackageReference(
                    repositoryURL: url,
                    versionRequirement: requirement.xcodeprojValue
                )
                remotePackageReferences[url] = packageReference
                pbxproj.add(object: packageReference)
            }
        }

        pbxProject.remotePackages = remotePackageReferences.sorted { $0.key < $1.key }.map { $1 }
        pbxProject.localPackages = localPackageReferences.sorted { $0.key < $1.key }.map { $1 }
    }

    private func generateAttributes(project: Project) -> [String: ProjectAttribute] {
        var attributes: [String: ProjectAttribute] = [:]

        // On Demand Resources tags
        if let knownAssetTags = try? knownAssetTagsFetcher.fetch(project: project), !knownAssetTags.isEmpty {
            attributes["KnownAssetTags"] = .array(knownAssetTags)
        }

        // BuildIndependentTargetsInParallel
        attributes["BuildIndependentTargetsInParallel"] = "YES"

        // Organization name
        if let organizationName = project.organizationName {
            attributes["ORGANIZATIONNAME"] = .string(organizationName)
        }

        // Class prefix
        if let classPrefix = project.classPrefix {
            attributes["CLASSPREFIX"] = .string(classPrefix)
        }

        // Last upgrade check
        if let lastUpgradeCheck = project.lastUpgradeCheck {
            attributes["LastUpgradeCheck"] = .string(lastUpgradeCheck.xcodeStringValue)
        }

        return attributes
    }

    private func determineProjectConstants() throws -> ProjectConstants {
        // TODO: Determine if this can be inferred by the set Xcode version
        .xcode13
    }
}
