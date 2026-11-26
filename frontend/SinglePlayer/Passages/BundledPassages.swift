import Foundation

/// Original practice passages written for MonkeyWrite and reviewed for the MVP.
/// The text is bundled for offline use. A subject-scoped source keeps every
/// passage in a round, including timed-mode continuations, in that subject.
/// Passages are dealt from a shuffle bag per subject (`PassageDeck`), so every
/// passage comes up once before any repeats, across rounds and launches.
struct BundledPassages: PassageSource {
    let subject: PassageSubject?
    private let deck: PassageDeck

    init(subject: PassageSubject? = nil, defaults: UserDefaults = .standard) {
        self.subject = subject
        self.deck = PassageDeck(name: subject?.rawValue ?? "all", defaults: defaults)
    }

    static let all: [Passage] = [
        Passage(
            id: "biology-cell-energy",
            text: "Cells need energy to grow, repair damage, and carry out daily tasks. Mitochondria help release usable energy from food. Some cells need more energy than others. Muscle cells, for example, use large amounts of energy to help the body move.",
            source: "MonkeyWrite · How cells use energy",
            subject: .biology
        ),
        Passage(
            id: "biology-immune-system",
            text: "The immune system helps protect the body from infection. White blood cells can recognize and attack harmful bacteria. Some immune cells remember germs they have encountered before. This memory helps the body respond more quickly if the same germs return.",
            source: "MonkeyWrite · How the body fights infection",
            subject: .biology
        ),
        Passage(
            id: "biology-cell-membrane",
            text: "Every cell has a membrane that separates it from its surroundings. This thin barrier controls what enters and leaves the cell. Water, nutrients, and waste move across it in different ways. Keeping this movement balanced helps the cell stay healthy and function properly.",
            source: "MonkeyWrite · The cell membrane",
            subject: .biology
        ),
        Passage(
            id: "biology-circulation",
            text: "The heart pumps blood through a network of blood vessels. Blood carries oxygen and nutrients to cells throughout the body. It also collects carbon dioxide and other waste. During exercise, the heart beats faster to help working muscles receive the oxygen they need.",
            source: "MonkeyWrite · Blood and circulation",
            subject: .biology
        ),
        Passage(
            id: "biology-breathing",
            text: "When you breathe in, air travels into your lungs. Oxygen moves from the lungs into the blood, while carbon dioxide moves in the opposite direction. The blood delivers oxygen to cells around the body. Breathing out removes carbon dioxide through the lungs.",
            source: "MonkeyWrite · Breathing and oxygen",
            subject: .biology
        ),
        Passage(
            id: "biology-digestion",
            text: "Digestion breaks food into smaller parts that the body can absorb. The process begins in the mouth, where chewing and saliva start breaking down food. Most nutrients enter the blood through the small intestine. The body uses them for energy, growth, and repair.",
            source: "MonkeyWrite · Digestion and nutrients",
            subject: .biology
        ),
        Passage(
            id: "biology-genes",
            text: "Genes contain instructions that help cells make proteins. These proteins influence many features of the body, including how it grows and functions. Children inherit genes from both biological parents. Many traits, such as height, depend on several genes as well as environmental conditions.",
            source: "MonkeyWrite · Genes and inherited traits",
            subject: .biology
        ),
        Passage(
            id: "biology-ecosystems",
            text: "An ecosystem includes living things and the physical environment around them. Plants, animals, and bacteria interact with sunlight, water, and soil. A change in one part can affect the others. For example, losing plants can reduce both food and shelter for nearby animals.",
            source: "MonkeyWrite · Life in an ecosystem",
            subject: .biology
        ),
        Passage(
            id: "biology-muscles",
            text: "Muscles pull on bones to help the body move. Many muscles work in pairs because they can pull but cannot actively push. When one muscle contracts, another can relax. Regular movement helps maintain muscle strength and supports the joints that connect our bones.",
            source: "MonkeyWrite · Muscles and movement",
            subject: .biology
        ),
        Passage(
            id: "biology-natural-selection",
            text: "Individuals within a species often have different inherited traits. Some traits help them survive and reproduce in a particular environment. Over many generations, those traits may become more common. This process is called natural selection, and it helps explain how populations change over time.",
            source: "MonkeyWrite · Natural selection",
            subject: .biology
        ),
        Passage(
            id: "history-printing-press",
            text: "The spread of movable type printing in Europe changed how information traveled. Printers could produce many copies of a text more quickly than scribes could copy them by hand. Books became more widely available, helping religious arguments, scientific discoveries, and political ideas reach new audiences.",
            source: "MonkeyWrite · The printing press",
            subject: .history
        ),
        Passage(
            id: "history-industrial-revolution",
            text: "The Industrial Revolution changed how goods were made and where people worked. Machines and factories expanded production, while growing cities attracted workers from rural areas. These changes created new opportunities, but many workers faced long hours, dangerous conditions, and crowded housing.",
            source: "MonkeyWrite · The Industrial Revolution",
            subject: .history
        ),
        Passage(
            id: "history-silk-roads",
            text: "The Silk Roads connected trading communities across Asia and beyond. Merchants carried silk, spices, and other goods through a network of routes. Ideas, beliefs, and technologies also traveled between regions. Most goods passed through many hands before reaching their final destination.",
            source: "MonkeyWrite · Trade along the Silk Roads",
            subject: .history
        ),
        Passage(
            id: "history-farming",
            text: "In several parts of the world, people gradually began growing crops and raising animals. Farming supported more permanent settlements and changes in how communities organized work. Extra food could support people with other roles, including builders and traders. These changes unfolded differently across regions.",
            source: "MonkeyWrite · Farming and early settlements",
            subject: .history
        ),
        Passage(
            id: "history-railways",
            text: "Railways made it possible to move people and goods across long distances more quickly. They connected farms, factories, ports, and growing cities. Building railway networks required large amounts of labor and money. Their expansion changed travel, trade, and the development of many communities.",
            source: "MonkeyWrite · The spread of railways",
            subject: .history
        ),
        Passage(
            id: "history-scientific-revolution",
            text: "During the Scientific Revolution, scholars in Europe developed new ways to investigate the natural world. Observation, experiments, and mathematics became increasingly important tools. Discoveries challenged some established explanations of nature. Printed books and scientific groups helped researchers share findings and debate their ideas.",
            source: "MonkeyWrite · The Scientific Revolution",
            subject: .history
        ),
        Passage(
            id: "history-voting-rights",
            text: "Campaigns for women’s voting rights took different forms around the world. Organizers gave speeches, published newspapers, and pressured governments to change the law. Progress was often uneven. In many places, discrimination continued to prevent some women from voting even after major legal victories.",
            source: "MonkeyWrite · Women and voting rights",
            subject: .history
        ),
        Passage(
            id: "history-public-health",
            text: "As cities grew, crowded housing and unsafe water helped diseases spread. Public health efforts gradually improved water supplies, waste removal, and access to health information. Scientific discoveries also changed ideas about infection. These developments helped communities prevent illness and respond more effectively to outbreaks.",
            source: "MonkeyWrite · The growth of public health",
            subject: .history
        ),
        Passage(
            id: "history-space-race",
            text: "During the Cold War, the United States and the Soviet Union competed to achieve major milestones in space. Their programs launched satellites, sent people into orbit, and developed new technology. The competition also encouraged investment in science education and captured public attention around the world.",
            source: "MonkeyWrite · The space race",
            subject: .history
        ),
        Passage(
            id: "history-studying-past",
            text: "Historians use letters, objects, photographs, and other evidence to investigate the past. They consider who created a source, why it was made, and what it leaves out. Comparing different sources helps historians develop explanations. New evidence can lead them to revise earlier conclusions.",
            source: "MonkeyWrite · Studying the past",
            subject: .history
        ),
        Passage(
            id: "cs-data-structures",
            text: "A data structure organizes information so a program can use it effectively. Arrays store elements in order, while hash maps associate keys with values. Choosing a suitable structure can make common tasks, such as finding an item or updating a record, more efficient.",
            source: "MonkeyWrite · Data structures",
            subject: .computerScience
        ),
        Passage(
            id: "cs-computer-memory",
            text: "A computer stores working data in memory so the processor can access it. Caches keep copies of selected data close to the processor. When a program reuses nearby information, the cache can reduce the time spent waiting for data from main memory.",
            source: "MonkeyWrite · Computer memory",
            subject: .computerScience
        ),
        Passage(
            id: "cs-algorithms",
            text: "An algorithm is a series of steps used to solve a problem. Different algorithms can produce the same result while requiring different amounts of work. Programmers compare these approaches to choose one that fits the task, the available memory, and the expected amount of data.",
            source: "MonkeyWrite · Algorithms",
            subject: .computerScience
        ),
        Passage(
            id: "cs-variables",
            text: "A variable gives a program a way to refer to a value. That value might represent a score, a name, or whether a round has ended. Clear variable names help readers understand the program. Data types describe the kinds of values a variable can hold.",
            source: "MonkeyWrite · Variables and values",
            subject: .computerScience
        ),
        Passage(
            id: "cs-recursion",
            text: "Recursion happens when a function calls itself to solve a smaller version of a problem. A base case stops the calls when the problem becomes simple enough. Each call has its own place on the call stack, which uses memory until that call returns.",
            source: "MonkeyWrite · Recursion",
            subject: .computerScience
        ),
        Passage(
            id: "cs-functions",
            text: "A function groups instructions that perform a particular task. It can receive inputs, carry out calculations, and return a result. Breaking a program into functions can make its behavior easier to understand. The same function can also be called from several places.",
            source: "MonkeyWrite · Functions",
            subject: .computerScience
        ),
        Passage(
            id: "cs-debugging",
            text: "Debugging is the process of finding and fixing problems in a program. A programmer may inspect variable values, read error messages, or follow the code step by step. Reproducing a problem consistently helps reveal its cause. After a fix, testing checks whether the expected behavior returns.",
            source: "MonkeyWrite · Debugging",
            subject: .computerScience
        ),
        Passage(
            id: "cs-databases",
            text: "A database stores information so an application can find and update it. For example, a game might store player names, scores, and completed rounds. A query requests particular information from the database. Organizing the data carefully helps keep records consistent as the application grows.",
            source: "MonkeyWrite · Databases",
            subject: .computerScience
        ),
        Passage(
            id: "cs-interpreted-compiled",
            text: "A compiler translates code before it runs, often producing machine instructions. An interpreter executes code through another program at runtime. Many languages use a combination of these approaches. Java, for example, compiles to bytecode that can be interpreted or compiled further while the program runs.",
            source: "MonkeyWrite · Interpreted and compiled languages",
            subject: .computerScience
        ),
        Passage(
            id: "cs-caches-cpu-memory",
            text: "The CPU uses instructions and data stored in memory. Accessing main memory takes time, so caches keep copies of selected information closer to the CPU. A cache hit means the requested information is available there. A cache miss means it must be fetched from another level.",
            source: "MonkeyWrite · Caches, the CPU, and memory",
            subject: .computerScience
        ),
    ]

    func allPassages() -> [Passage] {
        guard let subject else { return Self.all }
        return Self.all.filter { $0.subject == subject }
    }

    func nextPassage(excluding: [Passage.ID]) -> Passage {
        let passages = allPassages()
        let id = deck.deal(from: passages.map(\.id), excluding: excluding)
        // Every supported subject has ten passages, so this source is nonempty.
        return passages.first { $0.id == id } ?? passages[0]
    }
}
