import Contacts

struct PhoneContact: Identifiable {
    let id: String
    let name: String
    let number: String
}

@MainActor
final class ContactStore: ObservableObject {
    @Published var contacts: [PhoneContact] = []
    @Published var permissionDenied = false
    private let store = CNContactStore()

    func load() async {
        do {
            let allowed = try await store.requestAccess(for: .contacts)
            guard allowed else { permissionDenied = true; return }
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var loaded: [PhoneContact] = []
            try store.enumerateContacts(with: request) { contact, _ in
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                for phone in contact.phoneNumbers {
                    loaded.append(PhoneContact(id: "\(contact.identifier)-\(phone.identifier)",
                                               name: name.isEmpty ? phone.value.stringValue : name,
                                               number: phone.value.stringValue))
                }
            }
            contacts = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            permissionDenied = true
        }
    }
}
