class Persona {
  String id;
  String name;
  String description;
  String prompt;
  String? avatarPath;

  Persona({
    required this.id,
    required this.name,
    required this.description,
    required this.prompt,
    this.avatarPath,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'prompt': prompt,
        'avatarPath': avatarPath,
      };

  factory Persona.fromJson(Map<String, dynamic> json) {
    return Persona(
      id: json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name'] ?? '未命名',
      description: json['description'] ?? '',
      prompt: json['prompt'] ?? '',
      avatarPath: json['avatarPath'],
    );
  }
}
